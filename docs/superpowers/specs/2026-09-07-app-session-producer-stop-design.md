# App 會話的匯入與 Watch 生產者停用

日期：2026-09-07。依使用者夜間代行授權細化已確認的 `2026-09-06-cloud-sync-app-session-lifecycle-design.md` 第6、7節。這是架構整合的可獨立驗證子段，不是完整 App owner、帳號切換、真正 freeze 或發布。

基準：`fc712f3ea1fd88e0ea49accd425a8dc169858130`；程式候選81305f6的2520/186完整Core與未簽署平台結果只屬基準，不沿用為新程式驗收。版本維持1.7.0 (13)。

## 方案與範圍

採用各現有App生產者的一次性停止介面，再由小型本機生產者群組協調store撤銷與收尾。這讓未來單一App owner可以在任何await之前同步停用舊入口，但不讓群組創造帳號、inventory、seal或cleanup權威。

不採只取消Task：匯入driver可能忽略取消直到既有工作完成，Watch已排隊callback也可能晚到。不在此一次改完CloudAccountTransitionCoordinator與所有SwiftUI入口：其身分確認、同帳號離線reopen、bootstrap與真實authority仍需後續獨立整合。代價是本段完成仍不能啟用跨帳號同步。

不改資料／備份／同步／Watch wire格式、購買授權、語言、開發故事、100,000,000-byte與64MiB上限。保持既有Watch去重、prepared-command、可靠快照及reminder語意。不得搬移、清理、改綁正式資料。

## 共同介面

App層`@MainActor AppSessionProducer`具備同步`stopForSessionTransition()`與`waitForStoppedOperations() async throws`。停止不可重開、可重複呼叫；未停用時等待拋`AppSessionProducerDrainError.producerStillActive`。新會話必須建立新實例。

停止先設不可逆狀態，再撤銷入口、清除本身的顯示狀態、取消可取消工作。保存停用當時所有已接受Task的參照，直到它們真正終結；不能先把唯一handle設nil再宣告完成。

等待不對共享工作轉送等待者取消。可在入口檢查取消；等待期間取消的呼叫者可待已接受Task結束後再拋CancellationError。這不是即時取消等待API；成功return才表示該生產者已接受工作終結。其他等待者不受影響。無跨await同步鎖、無日期驅動cleanup。

## PatternInboxProcessor

保留現有actor driver與store adapter。現有store初始化方式維持；另接受真實`PatternInboxDriver`作為明確依賴注入入口，供隔離組裝與測試使用。不得複製driver或將舊operation重試到新store。

stop時清除本身pendingSelection、failure、notice，保存並取消operationTask／noticeTask。所有新process／resolve／retry／discard操作在停止後無副作用；每個operation完成及catch發布錯誤前都檢查停止狀態。停止後不再呼叫backup reminder的accept，不再顯示舊選取或成功通知。

`PatternBackupReminderPresenter`搬到獨立App來源檔以供實際來源no-host測試組裝；只允許獨立審查要求的重入／發布記帳，不改其BackupHistory或使用者dismiss／close語意。同步publisher可能在外層setter完成前呼叫stop；processor需在callout後恢復自身停止狀態、禁止新增工作。若回復被中斷匯入的reminder狀態，必須辨別之後的presenter變更，不得覆蓋使用者剛完成的dismiss／開啟備份設定，也不得回滾持久history。processor停止不冒充整個SwiftUI子樹、其他匯入畫面或既有reminder已被owner移除；那是後續generation隱藏邊界。

通知Task被替換時，取消不代表終結；所有尚未結束的舊通知工作仍須保留到completion，並納入drain。可用窄範圍delay注入驗證忽略取消的工作，但正式三秒通知計時不變。

## PhoneWatchSyncCoordinator

將`WatchConnectivityTransport`改成必填依賴，由既有iOS App呼叫端明確傳入`PhoneWatchSession()`；coordinator本身不建立live transport。其平台中性的邏輯移除外層iOS編譯限制以供macOS no-host實際來源測試；macOS App不建立或啟動此元件。PhoneWatchSession與WatchConnectivity系統實作仍保持iOS邊界。

stop同步設關閉狀態、解除project／entitlement訂閱，清除transport四個callback屬性，保存serialTask與三種retry／expiry Task後取消。已被transport或Combine另存的舊callback仍須檢查關閉狀態；僅把callback設nil不足以攔住它們。

Combine訂閱先經thread-safe callback gate登記，再建立跳到MainActor的Task；Task以defer解除登記，即使self已釋放。stop先close gate，拒絕之後的新登記；drain也等待先前已接受的callback完成。這個gate只用短同步鎖保護非同步排程前的登記與等待者，不跨await持鎖，不代替store或account權威。不能只在MainActor Task開始後登記，否則stop可能漏掉尚未排到的工作。

同一gate也涵蓋三種計時器的完整Task生命期；被取消／替換的舊計時器必須到實際終結才finish token。gate的非同步wait使用MainActor隔離，begin／close／finish仍可跨執行緒同步使用。同步transport callout可能重入stop，後續傳送／重試／recovery亦須拒絕。一般測試使用隔離screenshot entitlement；試用到期測試則使用真實coordinator的既有依賴注入入口與記憶體purchase／trial假實作，無live factory或授權API擴張。

所有新start／receive／publish及內部activate／send／recover／timer continuation，在關閉後不再傳送、建立timer或更動store／ledger。已排隊工作在`await previous.value`之後重新檢查關閉狀態。等待涵蓋停用前接受的serial尾端及timer；保留原串列順序。

不嘗試撤回已送到Watch的快照、不宣稱Watch遠端已清空。wire尚無account session證據；本段不啟用真實跨帳號Watch路徑。原正常單帳號start行為不改。

## AppSessionProducerGroup

群組不可改綁，持有單一store與固定producer陣列。stop在同一MainActor同步區段先標記停止、`store.revokeSessionWrites()`，再停止每個producer，沒有await。後續等待先等待各producer，再呼叫store的aggregate drain；任何錯誤都不產生成功結果。

群組成功只證明這些已登記本機元件終結，不是完整App freeze、資料健康、account-ready、inventory或cleanup授權。此段不新增KnitNoteApp的帳號owner或CloudAccountDomainLifecycle consumer；未來owner須先hide UI／invalidate cloud epoch，再協調這個群組與其他來源。

## 驗證

使用真實App來源、Core來源、PatternInboxDriver和隔離JSONProjectStore；controlled processing與transport只替換外部邊界。所有資料、BackupHistory defaults與ledger放獨立UUID fixture根／suite，拒絕任何live factory、CloudKit、Keychain、StoreKit、WatchConnectivity呼叫。

1. Inbox晚到成功、選取、一般失敗均不能在stop後發布；真實driver的取消忽略工作釋放前drain不完成。正常未停止路徑仍發布；stop後入口不再呼叫processing。
2. Watch同步入列後立即stop，舊command不執行、不回覆、不傳送；另存的四種callbacks、訂閱晚到回呼與timer在stop後無傳送或落盤。stop前既有正常snapshot／指令語意保留。
3. open wait明確拒絕；stop重複安全；兩個等待者都能終結；取消一個等待者不取消或提前終結共享工作。所有測試錯誤路徑釋放並join自有Task。
4. 群組stop回傳前store新mutation已拒絕；inbox真實工作未釋放前群組仍等待。獨立B store完整磁碟證據不變且仍可正常編輯。A來源與原生結果不改綁。
5. 原Inbox／BackupReminder／Watch Core與App來源契約保持有效。新的no-host harness只symlink實際來源，不複製或改寫App來源來讓測試通過；Xcode來源與測試membership同步更新。
6. 每個新增行為先RED後GREEN；獨立review後固定HEAD及所有追蹤內容，串列跑完整Core、no-host App producer套件與未簽署macOS/iOS建置。不得把編譯或靜態字串檢查冒充實際callback驗證。

## 夜間邊界

日常設計／本機實作依代行授權執行；沒有取得真實驗收與精確候選授權，不merge/push、簽署、安裝、上傳、送審、啟用正式雲端或清理正式資料。到2026-09-07 08:00Taipei停止啟動新工作，已接受原生工作先安全收尾留證據。

自我審查：介面單一、停用不可逆、driver與transport使用真實來源、等待不是取消證據；資料／wire／權限格式不變；完整owner／UI／account／Watch遠端界線明列，不以本段宣告整版完成。
