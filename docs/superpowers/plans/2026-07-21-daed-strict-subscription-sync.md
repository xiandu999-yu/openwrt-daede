# daed Strict Subscription Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 让 daed 原生面板、daed 自带 cron、LuCI 手动更新和 LuCI cron 都能严格同步订阅节点，并在代理运行时立即应用运行态。

**Architecture:** 保持现有 updateSubscription GraphQL 签名不变，在 pinned dae-wing 上维护一个 0006 补丁。补丁先在数据库事务里按节点 Link 严格对账并提交，再由 config 层用统一的 runLock 排队、合并运行态应用；锁顺序固定为 runLock → DB transaction，避免原生 Web 批量更新和并发 cron 随机失败或死锁。

**Tech Stack:** OpenWrt Makefile、Go 1.26、GORM/SQLite、GraphQL、POSIX Shell、dae-wing pinned source patches。

---

## 文件结构

- Create: daed/patches/0006-reconcile-stale-subscription-nodes.patch — dae-wing 严格同步、运行态应用及回归测试。
- Modify: daed/Makefile — 先同步发布基线到 2026.07.20-r1，再把 PKG_RELEASE 升到 2。
- Modify: docs/superpowers/specs/2026-07-21-daed-strict-subscription-sync-design.md — 记录保持旧 GraphQL 签名的最终取舍。

### Task 1: 在精确 pinned dae-wing 上建立失败测试

**Files:**
- Create in temporary pinned source: graphql/service/subscription/mutation_utils_test.go
- Reference: ci/pins.env
- Reference: daed/patches/0001 through 0005

- [ ] **Step 1: 准备精确源码并顺序应用现有补丁**

Clone dae-wing，checkout dc503088945812c11235b35362d2bfa1a4c3bdf0，并按编号依次 git apply 0001 到 0005。

Expected: 五个补丁 clean apply。

- [ ] **Step 2: 写入 DB 回归测试**

测试使用 db.InitDatabase(t.TempDir())，直接创建 Subscription、Node、Group 和 group_nodes 关系，不并行执行。加入这些测试：

    func TestReconcileKeepsCurrentReferencedNode(t *testing.T)
    func TestReconcileDeletesStaleUnreferencedNode(t *testing.T)
    func TestReconcileDeletesStaleNormalGroupNode(t *testing.T)
    func TestReconcileDetachesStaleFixedNode(t *testing.T)
    func TestReconcilePreservesNodeReferencedByFixedAndNormalGroups(t *testing.T)
    func TestReconcileAllLinksAlreadyExistSucceeds(t *testing.T)
    func TestReconcileRollsBackWhenNoValidSubscriptionNodesRemain(t *testing.T)

每个测试断言 nodes.subscription_id、group_nodes、节点 ID、最终订阅节点数和需要变更的 Group.Version。

- [ ] **Step 3: 验证测试先失败**

Run on Linux:

    go test -tags dae_stub_ebpf ./graphql/service/subscription -count=1

Expected: FAIL，原因是 reconcileSubscriptionNodes 尚不存在。

### Task 2: 实现事务内严格同步和运行态应用

**Files:**
- Modify in temporary pinned source: graphql/service/subscription/mutation_utils.go
- Modify in temporary pinned source: graphql/service/config/mutation_utils.go
- Modify in temporary pinned source: graphql/mutation.go
- Modify in temporary pinned source: cmd/run.go
- Modify in temporary pinned source: graphql/root_schema.go

- [ ] **Step 1: 增加串行更新锁和运行态依赖**

在 subscription/mutation_utils.go 引入 graphql/service/config，并增加：

    var subscriptionUpdateMu sync.Mutex

多个订阅可以并行下载；只把 BeginTx → 对账 → commit 放进该锁，避免 SQLite 多 writer。不要让该锁包住运行态应用。

- [ ] **Step 2: 实现严格节点对账 helper**

增加：

    func reconcileSubscriptionNodes(tx *gorm.DB, subID uint, links []string) error

实现规则：

    incomingLinks = 去重后的新 links
    existing = subscription_id == subID 的旧节点
    current = existing.Link 仍在 incomingLinks：保留 ID 和组关系
    staleFixed = stale 且至少被一个 policy=fixed 的组引用：subscription_id 置 NULL
    staleNormal = 其余 stale：先 node.AutoUpdateVersionByIds，再删除节点及 group_nodes
    newLinks = incomingLinks - current.Link：调用 node.Import
    finalCount = subscription_id == subID 的节点数；为 0 则返回错误

同一个 stale 节点同时属于 fixed 和普通组时按 staleFixed 处理，保留该节点和全部显式组关系。

- [ ] **Step 3: 统一 config.Run 的锁和事务顺序**

把 config.Run 的现有主体拆成 runLocked。显式 GraphQL Run 保留 TryLock 快速报错，但必须先拿 runLock 再开事务。新增阻塞等待的：

    func ApplyIfRunning(ctx context.Context) error

ApplyIfRunning 用 runLock.Lock() 排队，拿锁后重新检查 System.Running 和 modified；确实需要应用时才开事务调用 runLocked。修改 graphql/mutation.go 和 cmd/run.go，让显式运行与启动恢复都调用新的 config.Run(ctx, dry)，不再由调用方先开事务。所有路径的锁顺序统一为 runLock → DB transaction。

- [ ] **Step 4: 订阅提交后自动应用**

UpdateById 的顺序改为：

    links, err := fetchLinks(m.Link)
    subscriptionUpdateMu.Lock()
    tx := db.BeginTx(ctx)
    err = reconcileSubscriptionNodes(tx, subID, links)
    err = tx.Model(&m).Update("updated_at", time.Now()).Error
    err = AutoUpdateVersionByIds(tx, []uint{subID})
    err = tx.Commit().Error
    subscriptionUpdateMu.Unlock()
    err = config.ApplyIfRunning(ctx)

数据库提交失败时不应用。应用失败时数据库更新保留、mutation 返回“订阅已更新但应用失败”，modified 状态继续为 true，下一次可重试。

- [ ] **Step 5: 更新 schema 注释**

改为：

    # updateSubscription re-fetches and strictly reconciles subscription nodes. Stale nodes pinned by fixed groups become independent nodes.

- [ ] **Step 6: 格式化并运行回归测试**

Run:

    gofmt -w graphql/service/subscription/mutation_utils.go graphql/service/subscription/mutation_utils_test.go graphql/service/config/mutation_utils.go graphql/mutation.go cmd/run.go
    go test -tags dae_stub_ebpf ./graphql/service/subscription ./graphql/service/config -count=1 -race
    go test -tags dae_stub_ebpf ./graphql/service/group -count=1
    go test -tags dae_stub_ebpf ./graphql/... -count=1

Expected: 所有命令 exit 0。

### Task 3: 生成并接入 OpenWrt 补丁

**Files:**
- Create: daed/patches/0006-reconcile-stale-subscription-nodes.patch
- Modify: daed/Makefile:9

- [ ] **Step 1: 从临时源码生成统一 diff 补丁**

补丁只包含：

    graphql/service/subscription/mutation_utils.go
    graphql/service/subscription/mutation_utils_test.go
    graphql/service/config/mutation_utils.go
    graphql/mutation.go
    cmd/run.go
    graphql/root_schema.go

Subject: [PATCH] daed: strictly reconcile subscription updates

- [ ] **Step 2: 验证补丁顺序**

在全新的 pinned dae-wing checkout 上按 0001 到 0006 逐个运行 git apply --check 和 git apply。

Expected: 六个补丁都能按顺序 clean apply。

- [ ] **Step 3: bump daed 包版本**

在同步 v2026.07.20 发布基线后修改 daed/Makefile：

    PKG_RELEASE:=2

不修改 PKG_VERSION、PKG_SOURCE 或 PKG_HASH，因为只增加 Build/Prepare 阶段应用的本地补丁。

- [ ] **Step 4: 本地静态验证**

Run:

    git diff --check
    sh -n luci-app-daede/root/usr/share/luci-app-daede/daed-sub-update.sh

Expected: exit 0。

### Task 4: 构建并在 252 验证真实链路

**Files:**
- Deploy package artifact only; do not edit unrelated router files.

- [ ] **Step 1: 完成 Linux/SDK 构建门禁**

在 OpenWrt SDK 中运行：

    make package/daed/clean
    make package/daed/compile V=s

Expected: 生成 daed 2026.07.20-r2 对应架构包，补丁全部应用且 Go/eBPF 编译成功。

- [ ] **Step 2: 读取路由器实验清单并做只读基线**

确认 252 的架构、包管理器、当前 daed/LuCI 版本、服务状态、订阅数、节点数和更新日志。输出中隐藏订阅 URL、节点链接、密码和 token。

- [ ] **Step 3: 临时安装 r3 并验证原生面板**

备份当前包信息和配置数据库，上传 2026.07.20-r2 测试包，安装后只重启 daed。构造或选择可安全测试的订阅：普通组单独引用若干节点、fixed 组固定一个节点，然后在 daed 原生面板点击更新。

Expected:

    新节点立即进入运行态
    普通组引用的 stale 节点删除
    fixed stale 节点转为独立节点且组仍有效
    订阅节点数不再累积
    更新失败时页面收到明确错误

- [ ] **Step 4: 验证 daed cron、LuCI 手动按钮和 LuCI cron**

三条入口分别执行一次，检查数据库节点数、策略组关系、进程状态和 /tmp/luci-app-daede.daed-sub-update.log。不得输出订阅或节点链接。

- [ ] **Step 5: 回归代理访问并检查工作树**

确认代理访问正常、daed 没有重启循环或 reload timeout；运行 git status --short 和 git diff --check。

Expected: 只有计划内文件变更，diff 无空白错误。验证通过后再由用户决定 commit、push 和发布。
