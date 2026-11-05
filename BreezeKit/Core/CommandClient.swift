import Foundation
import Libbox

// Plain Swift snapshots of libbox data, so the app never touches Libbox types.

public struct TunnelStatus: Equatable {
    public var memory: Int64 = 0
    public var goroutines: Int32 = 0
    public var connectionsIn: Int32 = 0
    public var connectionsOut: Int32 = 0
    public var trafficAvailable = false
    public var uplink: Int64 = 0
    public var downlink: Int64 = 0
    public var uplinkTotal: Int64 = 0
    public var downlinkTotal: Int64 = 0

    public init() {}
}

public struct OutboundGroupItemInfo: Identifiable, Equatable {
    public var id: String { tag }
    public var tag: String
    public var type: String
    public var urlTestTime: Int64
    public var urlTestDelay: Int32
}

public struct OutboundGroupInfo: Identifiable, Equatable {
    public var id: String { tag }
    public var tag: String
    public var type: String
    public var selectable: Bool
    public var selected: String
    public var items: [OutboundGroupItemInfo]
}

public final class CommandClient: ObservableObject {
    public enum ConnectionType {
        case status
        case groups
        case log
        case clashMode
    }

    private let connectionType: ConnectionType
    private let logMaxLines: Int
    private var commandClient: LibboxCommandClient?
    private var connectTask: Task<Void, Error>?

    @Published public var isConnected = false
    @Published public var status = TunnelStatus()
    @Published public var groups: [OutboundGroupInfo] = []
    @Published public var logList: [String] = []
    @Published public var clashModeList: [String] = []
    @Published public var clashMode = ""

    public init(_ connectionType: ConnectionType, logMaxLines: Int = 500) {
        self.connectionType = connectionType
        self.logMaxLines = logMaxLines
    }

    public func connect() {
        if isConnected {
            return
        }
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.connect0()
        }
    }

    public func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        if let commandClient {
            try? commandClient.disconnect()
            self.commandClient = nil
        }
        isConnected = false
    }

    private func connect0() async {
        LibboxBootstrap.setup()
        let clientOptions = LibboxCommandClientOptions()
        switch connectionType {
        case .status:
            clientOptions.command = LibboxCommandStatus
        case .groups:
            clientOptions.command = LibboxCommandGroup
        case .log:
            clientOptions.command = LibboxCommandLog
        case .clashMode:
            clientOptions.command = LibboxCommandClashMode
        }
        clientOptions.statusInterval = Int64(NSEC_PER_SEC)
        guard let client = LibboxNewCommandClient(ClientHandler(self), clientOptions) else {
            return
        }
        do {
            for i in 0 ..< 10 {
                try await Task.sleep(nanoseconds: UInt64(Double(100 + (i * 50)) * Double(NSEC_PER_MSEC)))
                try Task.checkCancellation()
                do {
                    try client.connect()
                    await MainActor.run {
                        self.commandClient = client
                    }
                    return
                } catch {}
                try Task.checkCancellation()
            }
        } catch {
            try? client.disconnect()
        }
    }

    private final class ClientHandler: NSObject, LibboxCommandClientHandlerProtocol {
        private weak var owner: CommandClient?

        init(_ owner: CommandClient) {
            self.owner = owner
        }

        func connected() {
            DispatchQueue.main.async { [weak owner] in
                guard let owner else { return }
                if owner.connectionType == .log {
                    owner.logList = []
                }
                owner.isConnected = true
            }
        }

        func disconnected(_ message: String?) {
            DispatchQueue.main.async { [weak owner] in
                owner?.isConnected = false
            }
        }

        func clearLogs() {
            DispatchQueue.main.async { [weak owner] in
                owner?.logList.removeAll()
            }
        }

        func writeLogs(_ messageList: (any LibboxStringIteratorProtocol)?) {
            guard let messageList else {
                return
            }
            var incoming: [String] = []
            while messageList.hasNext() {
                incoming.append(messageList.next())
            }
            DispatchQueue.main.async { [weak owner] in
                guard let owner else { return }
                var list = owner.logList
                list.append(contentsOf: incoming)
                if list.count > owner.logMaxLines {
                    list.removeFirst(list.count - owner.logMaxLines)
                }
                owner.logList = list
            }
        }

        func writeStatus(_ message: LibboxStatusMessage?) {
            guard let message else {
                return
            }
            var status = TunnelStatus()
            status.memory = message.memory
            status.goroutines = message.goroutines
            status.connectionsIn = message.connectionsIn
            status.connectionsOut = message.connectionsOut
            status.trafficAvailable = message.trafficAvailable
            status.uplink = message.uplink
            status.downlink = message.downlink
            status.uplinkTotal = message.uplinkTotal
            status.downlinkTotal = message.downlinkTotal
            DispatchQueue.main.async { [weak owner] in
                owner?.status = status
            }
        }

        func writeGroups(_ groups: LibboxOutboundGroupIteratorProtocol?) {
            guard let groups else {
                return
            }
            var result: [OutboundGroupInfo] = []
            while groups.hasNext() {
                guard let group = groups.next() else { continue }
                var items: [OutboundGroupItemInfo] = []
                if let iterator = group.getItems() {
                    while iterator.hasNext() {
                        guard let item = iterator.next() else { continue }
                        items.append(OutboundGroupItemInfo(
                            tag: item.tag,
                            type: item.type,
                            urlTestTime: item.urlTestTime,
                            urlTestDelay: item.urlTestDelay
                        ))
                    }
                }
                result.append(OutboundGroupInfo(
                    tag: group.tag,
                    type: group.type,
                    selectable: group.selectable,
                    selected: group.selected,
                    items: items
                ))
            }
            DispatchQueue.main.async { [weak owner] in
                owner?.groups = result
            }
        }

        func initializeClashMode(_ modeList: LibboxStringIteratorProtocol?, currentMode: String?) {
            let list = modeList?.toArray() ?? []
            DispatchQueue.main.async { [weak owner] in
                owner?.clashModeList = list
                owner?.clashMode = currentMode ?? ""
            }
        }

        func updateClashMode(_ newMode: String?) {
            DispatchQueue.main.async { [weak owner] in
                owner?.clashMode = newMode ?? ""
            }
        }

        func write(_: LibboxConnections?) {}
    }
}

/// One-shot commands to the running tunnel.
public enum TunnelCommands {
    public static func selectOutbound(group: String, outbound: String) throws {
        LibboxBootstrap.setup()
        try LibboxNewStandaloneCommandClient()?.selectOutbound(group, outboundTag: outbound)
    }

    public static func urlTest(group: String) throws {
        LibboxBootstrap.setup()
        try LibboxNewStandaloneCommandClient()?.urlTest(group)
    }

    public static func setClashMode(_ mode: String) throws {
        LibboxBootstrap.setup()
        try LibboxNewStandaloneCommandClient()?.setClashMode(mode)
    }

    public static func closeService() {
        LibboxBootstrap.setup()
        try? LibboxNewStandaloneCommandClient()?.serviceClose()
    }

    /// Validates a sing-box config with the same core the tunnel uses.
    public static func checkConfig(_ config: String) -> String? {
        LibboxBootstrap.setup()
        var error: NSError?
        LibboxCheckConfig(config, &error)
        return error?.localizedDescription
    }

    public static func formatBytes(_ value: Int64) -> String {
        LibboxFormatBytes(value)
    }
}
