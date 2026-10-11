using System;
using System.Net;

namespace DiscordAccess
{
    internal static class TlsPolicy
    {
        // These switches affect this process only. Keep OS certificate validation
        // and protocol negotiation, including TLS 1.3 where Windows supports it.
        internal static void UseSystemDefaults()
        {
            AppContext.SetSwitch("Switch.System.Net.DontEnableSchUseStrongCrypto", false);
            AppContext.SetSwitch("Switch.System.Net.DontEnableSystemDefaultTlsVersions", false);
            ServicePointManager.SecurityProtocol = SecurityProtocolType.SystemDefault;
        }
    }
}
