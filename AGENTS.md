# AGENTS.md — weigate-gitops

GitOps-репозиторий Weigate: всё, что ArgoCD разворачивает в кластер выше bootstrap-слоя (SRS INF-2.2).
Требования — в `docs/SRS.md` репозитория [`weigate`](https://github.com/m5tshift/weigate), там же общие правила
в `AGENTS.md`. Ссылки вида «SRS 4.1.11» ведут на разделы SRS.

## Структура

```
apps/
  root.yaml              App of Apps
  platform/              Application платформенных компонентов
  services/              Application сервисов и тестовых компонентов
platform/<component>/    values и манифесты: local-path-provisioner, cert-manager, istio, envoy-rls,
                         cnpg, percona-mongodb, clickhouse, valkey, garage, openbao, external-secrets,
                         observability, arc, zot, karpenter, kwok, anvil,
                         network-policies
platform/strimzi/        оператор и CR Kafka, целиком сгенерированы Ansible-ролью из weigate
services/<component>/values.yaml   values чарта из Zot: сервисы, merchant-mock, rate-mock, payer-sim
services/<component>/values-full.yaml  оверлей полного стенда поверх values.yaml (компоненты минимального стенда)
services/<component>/application.yaml  Application компонента только полного стенда, чарт из Zot; не синхронизируется,
                                       переносится в apps/services при переходе на полный стенд (m5tshift/weigate#183)
```

## Правила

- **Только декларативные манифесты и values.** Скриптов и ручных шагов здесь нет.
- **Секретов нет.** Только `ExternalSecret` со ссылками на OpenBao (SRS INF-2.4).
- **Неймспейсы создаёт bootstrap-слой** (Terraform, SRS INF-2.2). Здесь нет `Namespace`
  и `CreateNamespace=true`.
- **Чарты компонентов Weigate берутся из Zot** как OCI-артефакты (SRS CI-5.3). Application указывает
  версию чарта, values лежат здесь.
- **Каждое изменение — через PR.** Исключение одно: CI основного репозитория пушит в `main` обновление
  тега образа и версии чарта через deploy key (SRS 4.1.11). Вручную `image.tag` и версия чарта не правятся.
  После merge или push ArgoCD применяет изменение сам (auto-sync, self-heal). `kubectl apply` и правка
  ресурсов в кластере запрещены.
- **`platform/strimzi/` вручную не редактируется:** правится Ansible-роль в `weigate`, манифесты
  генерируются заново (SRS INF-2.3).
- **Порядок развёртывания** задаётся `argocd.argoproj.io/sync-wave`: операторы и CRD раньше
  ресурсов, которые от них зависят.
- **Ресурсы** (SRS 6.2): у каждого пода `requests` и `limits`; сумма `requests` постоянной нагрузки —
  не больше 19 ГБ.
- **Реплики** (SRS 6.3): не меньше 2 у каждого сервиса. Меньше — только по порядку разгрузки SRS 6.2.
- **Сетевые политики** (SRS 4.1.10, 4.1.11): default-deny, разрешения — явными политиками Cilium.
- **Образы и чарты Bitnami запрещены.**
- **Окно заморозки** (SRS 6.3): auto-sync выключен, кластер зафиксирован на теге релиза, изменения
  только в ветки.
- Репозиторий публичный: правила SRS 4.1.11 действуют и здесь. Перед первым коммитом в клоне —
  `pre-commit install` (gitleaks и базовые проверки).

## Команды

Нужны `yamllint`, `kubeconform`, `yq`, `helm` и `kubectl`; те же проверки идут в CI (`.github/workflows/pr.yml`).

- `make lint` — yamllint (`.yamllint.yaml`).
- `make validate` — kubeconform для манифестов в `apps/` и `platform/` (values-файлы пропускаются),
  схемы CRD из закреплённого коммита datreeio/CRDs-catalog.
- `make render` — `helm template` чартов Istio и наблюдаемости с values из `platform/istio/` и
  `platform/observability/` (чарт, версия и values берутся из Application), `kubectl kustomize` для
  `platform/istio/mesh` и `platform/observability/config`; результат проверяет kubeconform.
- `make template` — `helm template` чарта каждого компонента из `services/` с его values: чарт берётся
  из клона `weigate` (`WEIGATE_DIR`, по умолчанию `../weigate`), результат проверяет kubeconform (со схемами CRD).
  Компонент с Application в `apps/services/` проверяется по правилам минимального стенда (1 реплика, без PDB,
  VirtualService и DestinationRule, ExternalSecret, есть экспорт OTel, requests и limits), его `values-full.yaml` —
  поверх `values.yaml`: requests и limits, Istio по SRS 4.1.9 без fault injection. Компонент с
  `services/<c>/application.yaml` — по правилам полного стенда: чарт из Zot, ≥ 2 реплики и PDB (1 реплика без PDB
  у `reconciliation-service` и `reporting-service`, SRS 6.2), каждый смонтированный Secret — из ExternalSecret.
- `make ddl` — DDL из `platform/clickhouse/full/ddl/` на ClickHouse в контейнере (нужен docker): два прогона подряд,
  витрины на тестовых строках в целевых таблицах.
- `make dashboards` — дашборды Grafana из `platform/observability/config/dashboards/`: валидный JSON, метрики
  запросов есть в коде `weigate` (`WEIGATE_DIR`) или у известного экспортера.
- `make policy` — правила из этого файла, видимые по тексту: нет `Namespace`, `CreateNamespace=true`,
  `Secret`, Bitnami; у каждого `Application` есть `argocd.argoproj.io/sync-wave`.
- `make test-policy` — проверка `policy` на фикстурах из `test/policy/`.
- `make precommit` — `pre-commit run --all-files` (gitleaks и базовые проверки).
