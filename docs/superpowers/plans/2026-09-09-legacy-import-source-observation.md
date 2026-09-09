# Legacy Import Source Observation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 從真實隔離檔案產生受限來源觀察、比對實際備份，並讓來源／會話改變使確認失效。

**Architecture:** 在既有 KnitNoteBackupService 增加 internal 原生觀察入口，共用 descriptor reader、附件列舉及驗證；不建立 account source issuer。新增一次性準備協調器，將實際內容摘要接入已完成的 consent model，仍不接 App 或任何 installer。輸出是樂觀內容觀察，不是原子快照或資料權限。

**Tech Stack:** Swift 6、Foundation、Darwin descriptor IO、CryptoKit SHA256、Swift Testing；沿用 root SwiftPM target，不加外部依賴。

**Spec:** `docs/superpowers/specs/2026-09-09-legacy-import-source-observation-design.md`（已確認），以及其上位 `2026-09-09-legacy-local-import-safety-design.md`。基準 `99ece4bcdc400ec640178af4e4427f11f79a425e`。

## Global Constraints

- 版本 1.7.0 (13)，保持现有 iOS18/macOS15/watchOS11 floors。
- 「輸出證明特定觀察時的內容相符，不證明歷史帳號歸屬、不簽發資料讀寫或安裝權限。」
- 「正常 App、Watch、CloudKit、Keychain、正式來源資格 issuer、持久 receipt、匯入安裝與 crash recovery 不在本切片接線。」
- 單檔上限採 backup 類別與100,000,000 bytes較小值；manifest/projection1,000,000、archive20,000,000、markup2,000,000、package4,000,000,000。不可改 portable backup 的200,000,000一般檔相容上限。
- 不改既有 consent model 的意圖／權限界線、Watch wire、source issuer、journal、清理政策或正式 factory。
- 新結果 internal、非 Codable、initializer受控；不接受 caller摘要偽造原生讀取結果。
- 不把全package載入記憶體；新增檔案雜湊使用64KiB分塊。所有累加先檢查溢位／預算。
- apply_patch改檔；單compiler lane；工具返回session時等待同一session，不重複啟動測試。
- 保留所有既有未提交檔案，尤其 `.superpowers/absent-source-design-progress.md`；不清理正式／其他暫存資料。
- 每項先RED再最小實作，個別review後精確本機commit。無merge/push/upload/送審或自動化操作。

## 檔案配置與現有接點

1. Modify `Sources/KnitNoteCore/Backup/KnitNoteBackupService.swift`：新原生snapshot型別與窄internal入口置於此檔，保持private/fileprivate建構界線；共用原有private helpers，不全面搬移大型檔案。
2. Create `Sources/KnitNoteCore/Backup/LegacyImportContentProjection.swift`：只有內容投影／摘要，不是物理資格。
3. Create `Tests/KnitNoteCoreTests/LegacyImportSourceObservationTests.swift`：實際來源／backup安全矩陣與同檔private fixture。
4. Create `Sources/KnitNoteCore/CloudSync/LegacyImportPreparationCoordinator.swift`：隔離準備與確認重驗，無正式呼叫。
5. Create `Tests/KnitNoteCoreTests/LegacyImportPreparationCoordinatorTests.swift`：受控制async邊界與真實檔案。
6. Create `docs/superpowers/reports/2026-09-09-legacy-import-source-observation-verification.md`：完整驗證證據。

已讀接點：service1152 `withLiveRegularFile`、1206 `validateUnchangedSource`、1436 `copyFileLimit`、1705 `referencedRelativePaths`、1712帶markup closure overload、1883 `descriptorMarkupPaths`、1960 `boundedMarkupEntryNames`、2029 `decodeManifest`。行號只供定位，執行前確認實際內容。Tests中 `makeServiceFixture` 與 `BackupFixture` 是private，不可假定跨檔可呼叫；新增測試自行建立最小fixture，完整媒體案例優先放在既有 `KnitNoteBackupServiceTests.swift` 重用其private fixture（這是允許的額外測試檔修改）。

## 共用驗證流程

執行目錄 `/Users/longzhenzhong/Documents/毛線編織 App/.worktrees/cross-device-sync-design`。先核對Git/branch/dirty、活動代理與compiler；ps遭sandbox拒絕就用正式require_escalated讀取，不猜測空閒。不重跑上一切片30tests當成本輪成果。

每次以新task-specific log保存完整命令／退出碼。先讀 `/tmp/task4-run-bounded.py` 確認存在及900秒限制，使用：

```sh
env -u KNITNOTE_RUN_CLOUDKIT_INTEGRATION CLANG_MODULE_CACHE_PATH=/tmp/knitnote-account-domain-jnjVrd/clang-cache python3 /tmp/task4-run-bounded.py 900 arch -arm64 swift test --disable-xctest --disable-sandbox --cache-path /tmp/knitnote-account-domain-jnjVrd/cache --config-path /tmp/knitnote-account-domain-jnjVrd/config --security-path /tmp/knitnote-account-domain-jnjVrd/security --no-parallel --filter 'LegacyImport|LegacyLocalImport|KnitNoteBackupServiceTests|KnitNoteBackupManifestTests|KnitNoteBackupPackagePlanTests|SyncRegularFileReaderTests'
```

Task內迭代filter可縮為新增suite；每項完成跑其受影響suite，最後只跑一次上述全相關集合。環境失敗與missing-symbol RED分開記錄，不能省略cache/runner後反覆失敗。若900秒超時，保留log並分析，不放寬斷言或直接沿用前次結果。

---

### Task 1: 原生來源觀察與確定性內容投影

**Files:** service、new projection、new source tests；若重用完整媒體fixture，修改既有backup tests。

**Interfaces:** 新 `LegacyImportContentEntry: Equatable, Sendable` 含 `relativePath: String, byteCount: Int64, sha256: Data`（純宣告可internal建構）；`LegacyImportContentProjection.digest(_ entries: [LegacyImportContentEntry]) throws -> Data`。service同檔宣告 `LegacyImportSourceObservation: Equatable, Sendable`，fileprivate init，唯讀properties `contentDigest: Data, entries: [LegacyImportContentEntry], rootIdentity: SyncRegularFileIdentity, fileIdentities: [String: SyncRegularFileIdentity]`。service新增 `observeLegacyImportSource() throws -> LegacyImportSourceObservation`。這些名稱後續照用。

- [x] 新增真實fixture和RED測試：

```swift
import Foundation
import CryptoKit
import Testing
@testable import KnitNoteCore

private func sourceFixture() throws -> (KnitNoteBackupService, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let live = root.appendingPathComponent("Source")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
    try JSONEncoder().encode(archive).write(to: live.appendingPathComponent("projects-v1.json"))
    return (KnitNoteBackupService(liveRoot: live, workRoot: root.appendingPathComponent("Work")), live, root)
}
@Suite struct LegacyImportSourceObservationTests {
    @Test func actualArchiveIsObservedWithoutWritingSource() throws {
        let (service, live, root) = try sourceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = live.appendingPathComponent("projects-v1.json")
        let bytes = try Data(contentsOf: url)
        let snapshot = try service.observeLegacyImportSource()
        let file = try #require(snapshot.entries.first)
        #expect(snapshot.entries.count == 1)
        #expect(file.relativePath == "projects-v1.json")
        #expect(file.sha256 == Data(SHA256.hash(data: bytes)))
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try service.observeLegacyImportSource() == snapshot)
    }
}
```

- [x] 跑新增suite，保存缺型別／方法RED；不得先加入production stub再稱未實作已測。
- [x] 實作投影：標籤UTF8 `KnitNote.LegacyImportContent.v1\0`；緊接UInt64 big-endian entry數；每entry依UTF8 lexicographic順序寫UInt64 path byte length、path bytes、UInt64 byteCount、32-byte SHA256。拒絕負size、非32bytehash、空／絕對／含空segment、`.`、`..`、反斜線、NUL的路徑、duplicate／case-diacritic aliases、缺archive；使用與service一致的EN_US_POSIX alias規則。投影累加含標籤/count最多1,000,000 bytes，先判斷再配置，hash不依Swift Hasher或locale排序。

```swift
// Encoding primitive inside LegacyImportContentProjection; actual numeric input checked nonnegative.
private static func appendWord(_ value: UInt64, to data: inout Data) {
    var big = value.bigEndian
    withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
}
// Budget each field BEFORE append:
// guard fieldBytes <= 1_000_000 - encoded.count else { throw KnitNoteBackupError.fileTooLarge }
// Hash only canonical encoded bytes: Data(SHA256.hash(data: encoded)).
```

- [x] 在service內實作原生觀察：打開root O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC，fstat保存rootIdentity；archive用既有bounded reader（20MB）讀取／decode／validate；附件集合重用原生參照規則及boundedMarkupEntryNames。增加budget-aware參照累積器，在每個新entry進入集合前扣除投影bytes，不能先建立無限制全集再檢查；原普通backup入口維持原行為。
- [x] 逐檔共用withLiveRegularFile取得descriptor；`limit=min(copyFileLimit,100_000_000)`、byteCount預檢、64KiB逐塊SHA256.update、呼叫copyChunkHook與validateUnchangedSource；保留device/inode，不保留整份附件Data。archive摘要必須對應用來列舉的原archive bytes。完成後重验root與每個path的descriptor identity、重新列舉參照集合相符；不聲稱此流程排除ABA或有全域freeze。

```swift
// Streaming loop shape in the existing service's descriptor closure:
var hash = SHA256()
var readBytes: Int64 = 0
var buffer = [UInt8](repeating: 0, count: 64 * 1024)
while true {
    let request = Int(min(Int64(buffer.count), limit - readBytes + 1))
    let n = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, request) }
    guard n >= 0 else { throw KnitNoteBackupError.unsafePackageEntry }
    if n == 0 { break }
    guard Int64(n) <= limit - readBytes else { throw KnitNoteBackupError.fileTooLarge }
    readBytes += Int64(n)
    hash.update(data: Data(buffer.prefix(n)))
    try copyChunkHook(source, readBytes)
}
try validateUnchangedSource(descriptor: descriptor, initialInfo: initialInfo, copiedBytes: readBytes)
```

上段以remaining+1只讀一個overrun probe；進入loop前要求0 ≤ readBytes ≤ limit ≤100,000,000，避免算術溢位。新增結果建構留在同檔fileprivate，其他檔不可直接造observation。

- [x] 補測試並GREEN：同內容不同root digest相同但rootIdentity不同；entry順序相反digest相同；同size內容變動digest不同；檔案rename替換同內容則identity不同；unsafe路徑/alias/negative/31、33bytehash拒絕；剛好投影cap可收、加1byte拒絕。透過現有beforeSourceEntryOpen/copyChunkHook作替換、symlink、hardlink、缺檔故障，確認source bytes保留。
- [x] 在既有backup test private fixture新增全媒體實測：project/yarn/label/journal、PDF與markup皆出現在entries，未参照快取不被加入；同步控制檔不被刪除或假稱已包含。
- [x] 跑受影響source/projection/backup/reader suites；自審、單項review、精確本機提交 `feat: observe legacy import source files safely`。

### Task 2: 實際備份比對及受控準備結果

**Files:** service、新source tests。Consumes Task1型別；Produces `LegacyImportBackupObservation: Sendable`（同service檔fileprivate init），含 `packageURL: URL, contentDigest: Data, source: LegacyImportSourceObservation`；service methods `prepareLegacyImportBackup(appVersion: String) throws -> LegacyImportBackupObservation` 及 `revalidateLegacyImportBackup(_ prepared: LegacyImportBackupObservation) throws`。

- [x] 寫RED測試（加在Task1 suite，同一private fixture）：

```swift
@Test func backupMatchesAndLaterSourceChangeIsRejected() throws {
    let (service, live, root) = try sourceFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try service.prepareLegacyImportBackup(appVersion: "1.7.0")
    #expect(prepared.contentDigest == prepared.source.contentDigest)
    try service.revalidateLegacyImportBackup(prepared)
    let archive = ProjectArchive(version: ProjectArchive.currentVersion,
        projects: [try StoredProject(name: "new edit")])
    try JSONEncoder().encode(archive).write(to: live.appendingPathComponent("projects-v1.json"), options: .atomic)
    #expect(throws: (any Error).self) { try service.revalidateLegacyImportBackup(prepared) }
    #expect(FileManager.default.fileExists(atPath: prepared.packageURL.path))
}
```

- [x] 原生prepare採S0→createPackage→驗證B→S1。B先以原inspectPackage做完整格式／圖片／markup驗證，再以Data子根的descriptor觀察取得實際投影；manifest size、byteCount及hash必須與實際entries一致，不接受宣告值代替實際hash。manifest/根讀取前後重驗身分；packageroot必須綁定本次service workRoot與成功createPackage回傳的exact owned路徑，不暴露任意備份URL作證據。

```swift
// Control flow inside prepareLegacyImportBackup, all called methods are defined by Tasks1/2:
let before = try observeLegacyImportSource()
let package = try createPackage(appVersion: appVersion)
// Internal helper observeValidatedLegacyPackage(at:) performs inspect + descriptor scan described above,
// returns native package content and physical root bindings.
let backup = try observeValidatedLegacyPackage(at: package)
let after = try observeLegacyImportSource()
guard before == after, backup.contentDigest == after.contentDigest else {
    throw KnitNoteBackupError.integrityMismatch("projects-v1.json")
}
// Construct fileprivate LegacyImportBackupObservation with source=after, packageURL and digest.
```

`observeValidatedLegacyPackage(at:) throws -> LegacyImportPackageObservation`為本Task在service同檔新增private helper；結果為fileprivate Equatable Sendable struct，含`contentDigest: Data, packageRootIdentity: SyncRegularFileIdentity, dataRootIdentity: SyncRegularFileIdentity`。`LegacyImportBackupObservation`另以fileprivate properties保存此結果、`workRootIdentity: SyncRegularFileIdentity`及標準化`liveRootURL: URL, workRootURL: URL`。service是value type，不發明object identity；binding定義為相同live/work根路徑及原生根identity，相同物理根的等價service可重驗，不同根不得。workRoot在createPackage後以安全descriptor取得身分。建立Data根觀察service時保留patternFolderNameContext，不能改舊schema或自動migrate才比對。package總量驗證包括manifest，且先預檢再大型內容讀取。新準備只接受本次createPackage的現行format2，不改原inspect的format1相容。

- [x] revalidate再次讀source及B，對source的內容、集合、root/file identity做全等，對B做实际內容／持有package身分重驗；源或備份被換根、被改manifest/asset必須拒絕。失敗不清理成功package或原始資料。source/backup observations需額外fileprivate保存service binding与package rootIdentity以拒絕foreign service；不能只檢查URL。
- [x] 增補實測：備份createdAt不同而content相同；package檔內容篡改；manifesthash篡改；同內容換package root；不同service重驗；S0後／copy中／S1前修改；普通backup100MB以上仍按舊契約可用，但新入口100MB+1拒絕。用縮小可注入測試budget作密集邊界，但至少一例native sparse檔超真實cap在讀取前拒絕，不能只測假比較函式。
- [x] 跑source/backup相關回歸，自審與review，精確本機提交 `feat: compare legacy source with verified backup`。

### Task 3: 隔離會話協調與確認前重驗

**Files:** new coordinator/tests、final report。Consumes Task2 service methods及既有 `LegacyLocalImportConsentModel`。Produces `@MainActor final class LegacyImportPreparationCoordinator`。初始化 `init(service: KnitNoteBackupService)`；`prepare(context: LegacyImportPreparationContext) async throws -> LegacyLocalImportConsentModel.Proposal`；`confirm(_ proposal: LegacyLocalImportConsentModel.Proposal, context: LegacyImportPreparationContext) async throws -> Bool`；`invalidate()`同步撤銷；`stopAndDrain() async`等受管native工作結束。Context為internal Equatable Sendable，欄位 `sourceSession: UUID, targetSession: UUID, accountDigest: Data, source: LegacyLocalImportSource`，不含來源URL或caller contentdigest。

- [x] 先建source fixture和RED測試，context用合成32byte帳號觀察，不建立真實帳號。測試prepare回傳proposal但未confirmed、confirm前修改原archive導致拒絕且副本保留；未確認帳號（digest非32byte或source不是requiresConfirmation）不啟動backup。

```swift
@Test @MainActor func revokedPreparationCannotConfirm() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let live = root.appendingPathComponent("Source")
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    let archive = ProjectArchive(version: ProjectArchive.currentVersion, projects: [])
    try JSONEncoder().encode(archive).write(to: live.appendingPathComponent("projects-v1.json"))
    let service = KnitNoteBackupService(liveRoot: live, workRoot: root.appendingPathComponent("Work"))
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = LegacyImportPreparationCoordinator(service: service)
    let context = LegacyImportPreparationContext(sourceSession: UUID(), targetSession: UUID(),
        accountDigest: Data(repeating: 1, count: 32), source: .availableLocalHistoryUnknown)
    let proposal = try await coordinator.prepare(context: context)
    coordinator.invalidate()
    #expect(try await coordinator.confirm(proposal, context: context) == false)
    await coordinator.stopAndDrain()
}
```

- [x] 協調器使用單一受管Task保存native同步prepare/revalidate結果；不可fire-and-forget。每次await前捕捉generation UUID，返回後要求相同generation/context；invalidate變更generation、撤銷consent，但不抹去用來drain的Task handle。busy時throw既有operationInProgress，不建立第二worker。private state持有成功package即使失效，保留檔案不清理。
- [x] private `makeObservation(prepared:context:preparationID:) -> LegacyLocalImportObservation`把Task2實際digests加context給既有model。prepare前／後重驗context；confirm先匹配本次proposal物件，對錯誤或舊proposal回false且不影響新pending，再在worker跑native revalidate，回來再次檢查generation/context才消費consent。第一次成功消費後第二次false；本輪無installer callback。

確認的固定順序：先以`===`核對pending proposal，再捕捉generation與pending context，等待受管原生重驗，返回MainActor後核對generation及context，最後才呼叫既有`consent.confirm(_:current:)`。`makeObservation`的三個Data欄位分別使用context.accountDigest、prepared.source.contentDigest、prepared.contentDigest，source/session欄位來自context，preparationID保留本次prepare產生的UUID。實作前核對既有Observation實際欄位名稱，不新增替代模型。

這裡的context是隔離呼叫端提供的會話觀察，不是原生帳號認證。隔離測試的擁有者在每次帳號／會話改變時必須呼叫invalidate，即使A→B→A也必須遞增generation；僅比較最終context不能發現這種變化。本切片不聲稱已有正式帳號事件listener。

- [x] Task3測試使用NSCondition或actor barrier控制await邊界，不sleep猜時間：copy中cancel、成功備份後cancel、revalidate中帳號A→B→A、舊worker晚到、新嘗試busy/retry、cross-owner proposal、prepared檔篡改。stopAndDrain返回前仍被barrier阻住時必須未完成；放行後副本與source可驗證，舊結果不能confirmed。sourceFixture函式在本測試檔private定義，不呼叫另一檔private helper。
- [x] 原生來源／副本讀取錯誤必須令當前提案失效後再傳回錯誤；單純錯誤proposal不撤銷有效新提案。沒有worker時invalidate不建立Task。無跨await同步lock。
- [x] 跑共用完整相關filter，記錄實際suite/數量/exit與warning；freeze後個別review再一次whole-unit review。檢查`rg -n 'LegacyImportPreparationCoordinator|observeLegacyImportSource|prepareLegacyImportBackup' Sources Tests KnitNote KnitNoteWatch`沒有App/Watch正式呼叫；git diff --check；所有既有入口diff保持不放寬。
- [x] 報告包含基準/候選SHA、精確命令/timeout/loghash、所有RED與環境錯誤、實際檔案不變證據、容量數值、review及修正、scope非聲稱：無歷史來源認證、無全域snapshot isolation、無安裝/receipt/crash recovery、無App/Watch/CloudKit接線。精確本機提交 `feat: revalidate legacy preparation before confirmation`。

## 計畫自審：覆蓋與依賴

| 規格要求 | 任務 |
| --- | --- |
| 真實descriptor讀取、逐檔hash、root/entry identity、受限projection | Task1 |
| 受驗證備份、S0/B/S1、時間不入digest、foreign service拒絕 | Task2 |
| 呈現／消費前重驗、await generation、取消drain、晚到結果 | Task3 |
| portable limits不變、同步較嚴限制、成功備份保留 | Tasks1/2，Task3取消矩陣 |
| 所有媒體與特殊檔案、同size修改、容量、manifest篡改 | Tasks1/2實檔測試 |
| 無來源權威／安裝、樂觀觀察限制、正式入口零使用 | 全域限制、Task3報告與reference audit |

Task1和Task2共用service／source tests，必須序列，不平行改檔。Task3依賴Task2結果，不能用caller摘要代替尚未完成的原生觀察。三項已執行並通過個別與整體審查；原始碼候選 cdd7a5e 的主代理最終回歸為165 tests / 9 suites，EXIT0。完整證據見 ../reports/2026-09-09-legacy-import-source-observation-verification.md。

執行結果：使用者委任後，已在本任務以子代理逐項實作及審查完成。審查裁決覆蓋原計畫順序：先做受限原生 admission，才做完整 inspect；package inventory 以串流逐筆計費，file1MB、directory4MB、depth4。沒有建立新使用者任務、重新啟用排程、合併或推送。
