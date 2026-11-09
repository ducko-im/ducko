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
        builder.withAllowsPLAIN(account.allowsPLAIN)
        builder.withPreferredResource(account.resource)
        builder.withUserAgent(SASL2UserAgent(device: SCDynamicStoreCopyComputerName(nil, nil) as String?))
        let rosterModule = RosterModule()
        let rosterVersion = account.rosterVersion
        rosterModule.setRosterVersionProvider { rosterVersion }
        let capsModule = CapsModule()
        let presenceModule = PresenceModule(capsModule: capsModule)
        let mucModule = MUCModule(resuming: resuming?.rooms, presenceModule: presenceModule)
        builder.withModule(ChatModule(mucModule: mucModule))
        builder.withModule(rosterModule)
        builder.withModule(presenceModule)
        builder.withModule(ServiceDiscoveryModule(resuming: resuming?.accountInfo))
        builder.withModule(capsModule)
        builder.withModule(VCardModule())
        builder.withModule(ReceiptsModule())
        builder.withModule(ChatStatesModule())
        builder.withModule(CarbonsModule())
        builder.withModule(MAMModule())
        builder.withModule(PingModule())
        builder.withModule(mucModule)
        builder.withModule(HTTPUploadModule())
        builder.withModule(JingleModule())
        let pepModule = PEPModule()
        pepModule.registerNotifyInterest(XMPPNamespaces.bookmarks2)
        pepModule.registerNotifyInterest(XMPPNamespaces.avatarMetadata)
        pepModule.registerNotifyInterest(XMPPNamespaces.omemoDevices)
        builder.withModule(pepModule)
        let omemoModule: OMEMOModule = if let omemoService {
            await omemoService.buildModule(for: account.jid, accountID: account.id, pepModule: pepModule, mucModule: mucModule)
        } else {
            OMEMOModule(pepModule: pepModule, mucModule: mucModule)
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
