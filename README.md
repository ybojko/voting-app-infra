# voting-app-infra

Terraform конфігурація для підняття інфраструктури в AWS (VPC + EKS).

## Структура

```
├── modules/          # Власні Terraform-модулі
├── environments/     # Середовища (dev/prod)
├── main.tf           # Основний вхід
├── variables.tf      # Змінні
├── outputs.tf        # Виходи
└── backend.tf        # Remote state (S3 + DynamoDB)
```

## Завдання

- Підняти VPC через публічний модуль `terraform-aws-modules/vpc/aws`
- Підняти EKS через публічний модуль `terraform-aws-modules/eks/aws`
- Написати щонайменше 1 власний модуль
- Remote state у S3 + DynamoDB lock
- IRSA для ESO (External Secrets Operator)
