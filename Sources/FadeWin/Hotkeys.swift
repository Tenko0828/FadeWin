import Carbon
import Foundation

final class Hotkeys {
    enum Action: UInt32, CaseIterable {
        case pause = 1, restore, lock

        var keyCode: UInt32 {
            switch self {
            case .pause: UInt32(kVK_ANSI_P)
            case .restore: UInt32(kVK_ANSI_R)
            case .lock: UInt32(kVK_ANSI_L)
            }
        }
    }

    private static let signature: OSType = 0x4664576E
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private let perform: (Action) -> Void

    init(perform: @escaping (Action) -> Void) {
        self.perform = perform
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == Hotkeys.signature,
                  let action = Action(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            // 菜单和快捷键共用主线程操作，避免 Fader 和提示面板跨线程访问
            DispatchQueue.main.async { [weak hotkeys] in hotkeys?.perform(action) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            NSLog("FadeWin: 安装快捷键处理器失败（\(status)）")
            return
        }
        for action in Action.allCases {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(action.keyCode, UInt32(optionKey | cmdKey), id,
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                registrations.append(reference)
            } else {
                NSLog("FadeWin: 注册快捷键失败（编号 \(action.rawValue)，错误 \(status)）")
            }
        }
    }

    deinit {
        for reference in registrations { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
