import UIKit
import BackgroundTasks
import UserNotifications

/// The system-owned progress surface supplies the live status. There is no
/// custom ActivityKit target and no assumption that displaying UI grants time.
@MainActor
final class PolicyBackgroundService {
    static let shared = PolicyBackgroundService()
    private var active: BGTask?
    private var identifier: String?
    private var registered = Set<String>()

    func submit(runID: String, begin: @escaping @Sendable () async -> Void) throws {
        guard UIApplication.shared.applicationState == .active else { throw PolicyContractError(message: L10n.text("请回到 App 前台主动开始运行")) }
        guard #available(iOS 26.0, *) else { Task { await begin() }; return }
        let identifier = "com.catfolio.ios.policy." + UUID().uuidString
        guard registered.insert(identifier).inserted else { throw PolicyContractError(message: L10n.text("任务已注册")) }
        let didRegister = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            self?.active = continued
            continued.progress.totalUnitCount = 1
            continued.expirationHandler = {
                Task { await PolicyRunCoordinator.shared.interrupt() }
            }
            Task { await begin() }
        }
        guard didRegister else { throw PolicyContractError(message: L10n.text("系统未允许后台任务注册。请使用前台运行并保留恢复记录。")) }
        self.identifier = identifier
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: L10n.text("策略编曲家"), subtitle: L10n.text("等待开始，只读分析"))
        request.strategy = .queue
        try BGTaskScheduler.shared.submit(request)
    }
    func progress(_ record: PolicyRunRecord) {
        guard #available(iOS 26.0, *), let task = active as? BGContinuedProcessingTask else { return }
        let steps = record.artifact["steps"].array
        let finished = steps.filter { ["SUCCEEDED", "UNKNOWN", "SKIPPED"].contains($0["status"].string) }.count
        task.progress.totalUnitCount = Int64(steps.count + 1)
        task.progress.completedUnitCount = Int64(finished + (record.dataComplete ? 1 : 0))
        task.updateTitle(L10n.text("策略编曲家"), subtitle: record.dataComplete ? L10n.text("已处理 \(finished)/\(steps.count) 条规则") : L10n.text("已读取 \(record.securities.count) 只证券"))
    }
    func end(success: Bool) {
        active?.setTaskCompleted(success: success)
        active = nil
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        identifier = nil
    }

    func requestNotifications() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }
    func notifyCompletion(_ record: PolicyRunRecord) async {
        guard record.notifyOnCompletion == true,
              ["SUCCEEDED", "INCOMPLETE"].contains(record.artifact["status"].string) else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.text("策略分析已结束")
        content.body = record.artifact["status"].string == "SUCCEEDED" ? L10n.text("结果已保存在本机。打开策略编曲家查看运行历史。") : L10n.text("部分数据不足，结果与原因已保存在运行历史。")
        content.userInfo = ["policyRunID": record.id]
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: record.id, content: content, trigger: nil))
    }
}
