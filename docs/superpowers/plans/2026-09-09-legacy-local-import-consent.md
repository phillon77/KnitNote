# Legacy Local Import Consent Implementation Plan

狀態：兩項隔離任務及個別／整體審查完成。原始碼提交 6fdc316、9020864；相關 30/4 測試通過。完整命令、流程偏差與未完成的正式匯入門檻见同日驗證報告。下列步驟保留為執行紀錄，不應重新派工。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立不具資料存取權限的隔離來源分類及一次性確認狀態機，拒絕來源／帳號／會話變動後的舊確認。

**Architecture:** 兩個 internal Core 元件：純分類政策與同步、單一 owner 的確認模型。輸入只代表觀察值，輸出只代表使用者意圖狀態；不產生 native authority、安裝 capability、receipt 或 CloudKit 操作。不接 App，避免把模型輸入冒充真實來源證據。

**Tech Stack:** Swift 6、Foundation、Swift Testing，既有 SwiftPM KnitNoteCore target；不加依賴或 Xcode membership。

**Spec:** `docs/superpowers/specs/2026-09-09-legacy-local-import-safety-design.md`，尤其第 8 節限定第一切片。使用者已確認；計畫基準 `d834ae15f9c6f1cb0b183c3278b0222d88e2ce21`。

## Global Constraints

- 版本維持 1.7.0 (13)。Package.swift 現有 floors：iOS 18、macOS 15、watchOS 11，均不修改。
- 「分類結果僅供狀態機測試，不可被正式入口採用為來源讀取或寫入資格。」
- 「它不授予實際安裝權限，不寫新持久格式，也不接正式 factory。」
- 不修改 source issuer、帳號 recovery／journal、Watch wire、備份、合併、清理或容量界線。
- 只新增下列四個 Swift 檔及本切片驗證報告；不修改使用者 `.superpowers/absent-source-design-progress.md` 或其他未提交報告。
- internal、無 Codable、無磁碟／網路／Keychain／時鐘讀取、無 URL、無 callback installer。不得加入「confirm 後自動寫入」捷徑。
- UUID 僅識別本模型中的嘗試／會話，不是安全認證；digest 僅是外部觀察值，本切片不證明它與真實檔案相符。
- 一條 compiler lane；每項有 RED→GREEN→檢視→精確本機提交。禁止 merge/push/upload/送審或啟動自動化。

## 檔案與驗證環境

建立：

- `Sources/KnitNoteCore/CloudSync/LegacyLocalImportPolicy.swift`：輸入分類及唯一純政策函式。
- `Tests/KnitNoteCoreTests/LegacyLocalImportPolicyTests.swift`：完整分類真值表。
- `Sources/KnitNoteCore/CloudSync/LegacyLocalImportConsentModel.swift`：值型輸入、reference owner、不可跨 owner 重用的提案 identity 與確認失效。
- `Tests/KnitNoteCoreTests/LegacyLocalImportConsentModelTests.swift`：重播、變動、多實例、順序測試。
- `docs/superpowers/reports/2026-09-09-legacy-local-import-consent-verification.md`：精確變更、實際命令／結果、未完成界線。

SwiftPM 自動發現上述檔案；不要改 `.pbxproj`、App target 或既有測試 harness links。先確認 cwd 為 `.worktrees/cross-device-sync-design`，branch `docs/cross-device-sync-design`，檢查 HEAD、dirty diff、活動代理與 compiler。ps 如遭拒絕，使用正式提權檢查後才啟動 compiler，不猜測全機空閒。

已核對 `/tmp/task4-run-bounded.py` 為 timeout/exit 記錄器，執行前重新核對內容。所有以下測試命令都從 worktree 執行；完整輸出保存到新建的 task-specific 暫存目錄，記錄絕對 log 路徑。不得覆蓋前一切片 logs。

共同命令前綴（每次實際執行須記錄完整展開命令）：

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --no-parallel --filter LegacyLocalImport
```

使用目前 root Package.swift，不使用 App harness。初次 missing-symbol RED 是新增型別的預期；其餘編譯錯誤不是行為 RED。若環境權限問題，先診斷，不能改斷言遮掩。

---

### Task 1: 明確分開來源分類與讀寫權限

**Files:** Create `LegacyLocalImportPolicy.swift` 及 `LegacyLocalImportPolicyTests.swift`，完整路徑見上。

**Interfaces:** Produces 下列全部 internal 型別；Task 2 只消費 `decision(for:) == .requiresConfirmation`，不接受其他分類作為可確認來源。

- [x] 寫分類表測試（Swift Testing，`@testable import KnitNoteCore`）：

```swift
import Testing
@testable import KnitNoteCore

@Suite struct LegacyLocalImportPolicyTests {
    @Test func sourceTable() {
        let rows: [(LegacyLocalImportSource, LegacyLocalImportDecision)] = [
            (.availableLocalHistoryUnknown, .requiresConfirmation),
            (.provenNeverBound, .useExistingSourceFlow),
            (.currentAccount, .useExistingAccountRecovery),
            (.foreignAccount, .blocked),
            (.accountUnknown, .blocked),
            (.unverifiedRecovery, .blocked),
            (.invalidContent, .blocked),
            (.unresolvedWatchState, .blocked)
        ]
        for (source, expected) in rows {
            #expect(LegacyLocalImportPolicy.decision(for: source) == expected)
        }
    }
}
```

- [x] 跑共同命令，確認 missing types/functions 的 RED；保存退出碼。
- [x] 在指定 source 檔加入最小實作：

```swift
// Observation-only policy. Never grants source access or installation authority.
enum LegacyLocalImportSource: CaseIterable, Sendable {
    case availableLocalHistoryUnknown, provenNeverBound, currentAccount
    case foreignAccount, accountUnknown, unverifiedRecovery
    case invalidContent, unresolvedWatchState
}
enum LegacyLocalImportDecision: Equatable, Sendable {
    case requiresConfirmation, useExistingSourceFlow, useExistingAccountRecovery, blocked
}
enum LegacyLocalImportPolicy {
    static func decision(for source: LegacyLocalImportSource) -> LegacyLocalImportDecision {
        switch source {
        case .availableLocalHistoryUnknown: .requiresConfirmation
        case .provenNeverBound: .useExistingSourceFlow
        case .currentAccount: .useExistingAccountRecovery
        case .foreignAccount, .accountUnknown, .unverifiedRecovery,
             .invalidContent, .unresolvedWatchState: .blocked
        }
    }
}
```

- [x] 再跑共同命令，確認分類測試真的執行且 GREEN。
- [x] 檢視來源中沒有 public、Codable、存取／安裝相依；精確 diff check，只提交 Task 1 兩個檔案，commit message `feat: model legacy import source decisions`。

### Task 2: 一次性確認與變動失效模型

**Files:** Create `LegacyLocalImportConsentModel.swift` 及 `LegacyLocalImportConsentModelTests.swift`；最後建立驗證報告。

**Interfaces:** Consumes Task 1 policy；Produces 下列 internal declarations。所有 mutation 為同步呼叫，模型標 `@MainActor`，同一 owner 跨多視窗共享的組裝不在本切片接線。

- [x] 先寫以下型別使用測試，觀察 missing-symbol RED：

```swift
import Foundation
import Testing
@testable import KnitNoteCore

@Suite @MainActor struct LegacyLocalImportConsentModelTests {
    private func observation() -> LegacyLocalImportObservation {
        .init(source: .availableLocalHistoryUnknown,
              sourceDigest: Data(repeating: 1, count: 32),
              backupDigest: Data(repeating: 2, count: 32),
              accountDigest: Data(repeating: 3, count: 32),
              sourceSession: UUID(), targetSession: UUID(), preparation: UUID())
    }
    @Test func oneShotAndNoAutomaticAcceptance() throws {
        let model = LegacyLocalImportConsentModel()
        let current = observation()
        #expect(model.state == .idle)
        let proposal = try #require(model.present(current))
        #expect(model.state == .awaitingConfirmation)
        #expect(model.confirm(proposal, current: current))
        #expect(model.state == .confirmedIntentOnly)
        #expect(!model.confirm(proposal, current: current))
    }
    @Test func foreignOwnerAndStaleProposalCannotConfirm() throws {
        let a = LegacyLocalImportConsentModel()
        let b = LegacyLocalImportConsentModel()
        let current = observation()
        let old = try #require(a.present(current))
        let fresh = try #require(b.present(current))
        #expect(!b.confirm(old, current: current))
        #expect(b.confirm(fresh, current: current))
        a.invalidate()
        #expect(!a.confirm(old, current: current))
    }
    @Test func everyChangedBindingInvalidates() throws {
        for field in 0..<7 {
            let model = LegacyLocalImportConsentModel()
            let current = observation()
            let proposal = try #require(model.present(current))
            var changed = current
            switch field {
            case 0: changed.source = .foreignAccount
            case 1: changed.sourceDigest = Data(repeating: 8, count: 32)
            case 2: changed.backupDigest = Data(repeating: 8, count: 32)
            case 3: changed.accountDigest = Data(repeating: 8, count: 32)
            case 4: changed.sourceSession = UUID()
            case 5: changed.targetSession = UUID()
            default: changed.preparation = UUID()
            }
            #expect(!model.confirm(proposal, current: changed))
            #expect(model.state == .invalidated)
            #expect(!model.confirm(proposal, current: current))
        }
    }
}
```

- [x] 實作以下完整最小模型；Bool 只代表本模型收到符合當前觀察的確認，不能用作 installer admission。Proposal 是記憶體物件 identity，不用可序列化 token：

```swift
import Foundation

struct LegacyLocalImportObservation: Equatable {
    var source: LegacyLocalImportSource
    var sourceDigest: Data
    var backupDigest: Data
    var accountDigest: Data
    var sourceSession: UUID
    var targetSession: UUID
    var preparation: UUID
    var canPresent: Bool {
        LegacyLocalImportPolicy.decision(for: source) == .requiresConfirmation
            && sourceDigest.count == 32 && backupDigest.count == 32
            && accountDigest.count == 32
    }
}

@MainActor final class LegacyLocalImportConsentModel {
    enum State: Equatable { case idle, awaitingConfirmation, confirmedIntentOnly, invalidated }
    final class Proposal { fileprivate init() {} }
    private(set) var state: State = .idle
    private var pending: (proposal: Proposal, observation: LegacyLocalImportObservation)?

    func present(_ observation: LegacyLocalImportObservation) -> Proposal? {
        invalidate()
        guard observation.canPresent else { return nil }
        let proposal = Proposal()
        pending = (proposal, observation)
        state = .awaitingConfirmation
        return proposal
    }
    func confirm(_ proposal: Proposal, current: LegacyLocalImportObservation) -> Bool {
        guard let pending, pending.proposal === proposal else { return false }
        guard pending.observation == current, current.canPresent else {
            invalidate()
            return false
        }
        self.pending = nil
        state = .confirmedIntentOnly
        return true
    }
    func invalidate() {
        pending = nil
        state = .invalidated
    }
}
```

`LegacyLocalImportSource` 加 `Equatable` conformance，供 Observation synthesis；這是 Task 2 唯一對 Task 1 source 的修改。禁止加入 disk encoding、期限、重試 queue 或 callbacks。

- [x] 再新增邊界測試，再跑 RED/GREEN：

```swift
// Add inside LegacyLocalImportConsentModelTests; uses its observation() fixture.
@Test func blockedAndMalformedNeverPresent() {
    for source in LegacyLocalImportSource.allCases {
        var value = observation(); value.source = source
        let model = LegacyLocalImportConsentModel()
        #expect((model.present(value) != nil) == (source == .availableLocalHistoryUnknown))
    }
    for length in [0, 31, 33] {
        for field in 0..<3 {
            var value = observation()
            switch field {
            case 0: value.sourceDigest = Data(repeating: 0, count: length)
            case 1: value.backupDigest = Data(repeating: 0, count: length)
            default: value.accountDigest = Data(repeating: 0, count: length)
            }
            #expect(LegacyLocalImportConsentModel().present(value) == nil)
        }
    }
}
@Test func replacementAndReopenDoNotReuseConfirmation() throws {
    let model = LegacyLocalImportConsentModel()
    let value = observation()
    let old = try #require(model.present(value))
    let new = try #require(model.present(value))
    #expect(!model.confirm(old, current: value))
    #expect(model.confirm(new, current: value))
    let reopened = LegacyLocalImportConsentModel()
    #expect(!reopened.confirm(new, current: value))
    #expect(reopened.state == .idle)
    model.invalidate() // models explicit account change A -> B -> A / cancel
    #expect(!model.confirm(new, current: value))
}
@Test func invalidPresentationRevokesPreviousProposal() throws {
    let model = LegacyLocalImportConsentModel()
    let value = observation()
    let old = try #require(model.present(value))
    var malformed = value
    malformed.backupDigest = Data()
    #expect(model.present(malformed) == nil)
    #expect(model.state == .invalidated)
    #expect(!model.confirm(old, current: value))
}
```

新增案例若立即 GREEN，如實記錄為補強測試，不捏造行為 RED；前述初始 RED 與相應最小實作才是本項 TDD 起點。A→B→A 同 hash 但不同 targetSession 已由 everyChangedBindingInvalidates 的 case 5 覆蓋；真正 App 帳號事件接線未測。

- [x] 完成針對性測試後做一次相關回歸：共同命令的 filter 改為 `LegacyLocalImport|SyncAccountSourceStateTests|JSONProjectStoreSessionAdmissionTests`，900 秒；觀察全部 suite 名稱、退出碼與結果，不用預估 test count 代替。
- [x] 自查／所選執行方式的 review：對照規格第 8 節、實際四檔 diff；特別驗證舊 proposal 不能清掉或確認新 proposal、malformed present 會撤掉舊提案、失效後不能用原觀察復活。Review 若指出行為錯誤，先加入可重現 RED 再改。
- [x] 建立驗證報告：記錄完整 SHA／dirty 檔案、RED/GREEN 命令與 logs、實際 suite/test 數、review findings／處置、`git diff --check`；明列「無真實來源認證、無安裝、無 crash-recovery 實作、無正式啟用」。
- [x] 確認只有本項三個 source/test 變更與報告；精確本機提交，message `feat: model one-shot legacy import confirmation`。不觸碰其他 untracked 文件。

## Spec coverage 與完成邊界

| 規格 | 本計畫覆蓋 |
| --- | --- |
| §2 來源分類 | Task 1 的分類真值表；是 policy model，不是資格 issuer |
| §3 確認元件、§4 當次綁定 | Task 2 的 observations／proposal；來源 digest 真實擷取、備份與 UI 均未接線 |
| §4/§5 來源、帳號、取消、重開失效 | Task 2 模型測試；不聲稱磁碟交易或真實程序終止已測 |
| §6 Watch 不改綁 | Task 1 unresolvedWatchState blocked；無 Watch 資料或 wire 操作 |
| §7(1–5) | 只有分類與確認失效的純模型部分；無 native store／檔案驗證聲稱 |
| §7(6–10) | 依 §8 留給持久交易／整合切片，不用純模型測試冒充其完成 |
| §7(11)、§8 隔離 | internal 型別、無 App 參照、無 I/O／Codable；diff 與 reference 搜尋核對，未跑 App startup 測試 |

最後搜尋 `rg -n 'LegacyLocalImport' Sources Tests KnitNote KnitNoteWatch`，預期只有本切片四檔；若出現正式入口呼叫，視為超範圍。新 public API／native authority／receipt 一律不在完成定義內。因本次僅 internal 純模型，不為此重跑數十分鐘全套或平台簽署建置；未來實際整合候選仍需完整驗證。

## 計畫自審與交接

已按核准規格 §8 限縮為兩項獨立可測交付，沒有宣稱完整匯入已涵蓋。型別、fixture、函式簽名與測試命令已具體列出；執行前仍需依實際 compiler 訊息修正 Swift 隔離標註，不得改變上述行為契約。

執行可選同一任務內的逐項 subagent＋review，或使用 executing-plans 在本任務內依序執行；不建立新的使用者任務。計畫完成不是實作完成，尚未執行任何測試。
