# SYNC.md — upstream(exchange-infra) 동기화 규칙

## 관계

- **upstream (source of truth, 비공개)**: `exchange-infra`
- **이 리포 (공개 mirror)**: `mock-trading-platform-infra`
- **방향**: upstream → mock **단방향**. mock 의 변경을 upstream 으로 역류시키지 않는다.

mock 은 upstream 의 **Terraform 구조/로직을 placeholder + mock 네이밍으로** 가진다.
upstream 은 실제 account/state bucket 이 적용된 인스턴스이고, mock 은 그 템플릿이다.
**따라서 동기화는 "파일 복사"가 아니라 "로직 이식"이다.**

> ⚠️ 과거에 upstream account 가 공개 리포로 복사되어 리포를 통째로 삭제·재생성한
> 사고가 있었다. 아래 C 분류와 `scripts/sync-guard.sh` 는 그 재발 방지가 목적이다.

---

## 분류 — 무엇을 어떻게 다루나

| 분류 | 처리 | 이 리포의 대상 |
|---|---|---|
| **A. 구조/로직** | upstream → mock **이식**(네이밍 변환하여) | `envs/dev/*.tf`(eks/vpc/iam/ecr/storage 구조·리소스 정의), `outputs.tf`, `providers.tf`, `variables.tf`, `alb_policy.json`, README 절차 |
| **B. 네이밍** | **변환**(무시 아님) | `exchange` → `mock-trading-platform`, `exchange-dev` → `mock-trading-platform-dev`. `var.cluster_name`, 리소스 `Name` 태그, role 이름 등 |
| **C. account/state/시크릿** | **이식 금지 / placeholder·자체값 유지** (= 민감정보 drift 는 무시) | `terraform.tfvars`(실제 값), `backend.hcl`(`<aws-account-id>` placeholder 유지), 모든 12자리 account ID, `*.tfstate*`, `drift-check.tfplan`, 콘크리트 VPC/subnet/ARN |

**"민감정보 drift 는 무시한다"** = C 분류. upstream 이 구체값으로 바뀌어도 mock 은
placeholder/자체 네이밍을 그대로 둔다. 이 drift 는 의도된 것이며 맞추지 않는다.

> `backend.hcl` 의 `bucket = "...-<aws-account-id>-tfstate"` 처럼 mock 은 account 를
> **placeholder 로 유지**한다. upstream 의 실제 bucket 이름을 절대 복사하지 않는다.

---

## 동기화 절차

upstream(`exchange-infra`)에 변경이 생겼을 때:

1. **변경 성격 분류** — A(구조/로직)만 이식 대상. B는 변환, C는 건드리지 않음.
2. **로직 이식** — 해당 `.tf`/부분을 mock 에 반영하되:
   - 모든 `exchange*` 네이밍을 `mock-trading-platform*` 로 변환(B)
   - 실제 account/bucket/VPC/ARN 이 보이면 placeholder 로 되돌림(C)
3. **가드 실행** (필수):
   ```bash
   ./scripts/sync-guard.sh
   ```
   `✓ 통과` 가 떠야 한다. ❌ 가 뜨면 upstream 값/네이밍이 새어든 것 — 2번으로 돌아간다.
4. **`terraform fmt -recursive` / `validate`** 로 형식·구문 확인.
5. **PR** 로 올린다. main 직접 푸시 금지.

### pre-push 자동화 (권장)
```bash
ln -sf ../../scripts/sync-guard.sh .git/hooks/pre-push
```
이후 `git push` 마다 가드가 자동 실행되어, 위반 시 푸시가 차단된다.

---

## 빠른 체크리스트

- [ ] 이식한 변경이 A(구조/로직)인가? (C 라면 멈춤)
- [ ] 모든 `exchange*` → `mock-trading-platform*` 변환했는가?
- [ ] account/bucket/VPC/ARN 이 placeholder 인가?
- [ ] `./scripts/sync-guard.sh` 통과 + `terraform validate` 통과했는가?
- [ ] PR 로 올렸는가?
