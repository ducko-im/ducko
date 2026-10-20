import DuckoXMPP
import Foundation
import SystemConfiguration

public struct DefaultXMPPClientFactory: XMPPClientFactory {
    public init() {}

    public func makeClient(
        account: Account,
        password: String,
        resuming: StreamResumeContext?,
        requireTLSOverride: Bool?,
        omemoService: OMEMOService?
    ) async -> (XMPPClient, StreamManagementModule) {
        var builder = XMPPClientBuilder(
            domain: account.jid.domainPart,
            username: account.jid.localPart ?? "",
            password: password
        )
        builder.withRequireTLS(requireTLSOverride ?? account.requireTLS)
        builder.withPreferredResource(account.resource)
        builder.withUserAgent(SASL2UserAgent(device: SCDynamicStoreCopyComputerName(nil, nil) as String?))
        let rosterModule = RosterModule()
        let rosterVersion = account.rosterVersion
        rosterModule.setRosterVersionProvider { rosterVersion }
        builder.withModule(ChatModule())
        builder.withModule(rosterModule)
        builder.withModule(PresenceModule())
        builder.withModule(ServiceDiscoveryModule())
        builder.withModule(CapsModule())
        builder.withModule(VCardModule())
        builder.withModule(ReceiptsModule())
        builder.withModule(ChatStatesModule())
        builder.withModule(CarbonsModule())
        builder.withModule(MAMModule())
        builder.withModule(PingModule())
        builder.withModule(MUCModule(resuming: resuming?.rooms))
        builder.withModule(HTTPUploadModule())
        builder.withModule(JingleModule())
        let pepModule = PEPModule()
        pepModule.registerNotifyInterest(XMPPNamespaces.bookmarks2)
        pepModule.registerNotifyInterest(XMPPNamespaces.avatarMetadata)
        pepModule.registerNotifyInterest(XMPPNamespaces.omemoDevices)
        builder.withModule(pepModule)
        let omemoModule: OMEMOModule = if let omemoService {
            await omemoService.buildModule(for: account.jid, accountID: account.id, pepModule: pepModule)
        } else {
            OMEMOModule(pepModule: pepModule)
        }
        builder.withModule(omemoModule)
        builder.withModule(BlockingModule())
        builder.withModule(StylingModule())
        builder.withModule(ChannelSearchModule())
        builder.withModule(RegistrationModule())
        builder.withModule(OOBModule())
        builder.withModule(CSIModule())
        let sm = StreamManagementModule(previousState: resuming?.streamManagement)
        builder.withModule(sm)
        builder.withInterceptor(sm)
        return await (builder.build(), sm)
    }
}
