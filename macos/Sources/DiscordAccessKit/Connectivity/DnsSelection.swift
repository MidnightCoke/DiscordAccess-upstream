/// One DNS candidate's connection (Windows `IDnsCandidateConnection`).
public protocol DnsCandidate: AnyObject {
    var provider: DnsProvider { get }
    /// Checks that Discord answers through this candidate; throws `ConnectivityFailure` when it does not.
    func verify(cancel: Cancellation) throws
    /// Closes the candidate completely; throws when that cannot be done safely.
    func close() throws
}

/// Picks the session's DNS candidate (Windows `DnsSelection`).
public enum DnsSelection {
    /// Opens the candidates of `options` one after another and returns the first that works; the caller then owns it.
    /// In automatic mode each candidate is verified, and one that fails with a `ConnectivityFailure` is closed before the
    /// next opens. A provider the user named is opened without verification, as before automatic selection existed.
    ///
    /// These end the selection without trying another provider: a failure to open (package integrity or engine start
    /// must not be hidden by another provider), any other error, an HTTP 429 (selection never tries to get past Discord's
    /// rate limit with another endpoint), a canceled check, a candidate that cannot be closed, and cancellation
    /// (`CancellationError`). When every candidate fails, only a fixed message is kept (DNS-E02).
    public static func select(_ options: DnsOptions, open: (DnsProvider, Cancellation) throws -> DnsCandidate,
                              log: ((String) -> Void)? = nil, cancel: Cancellation) throws -> DnsCandidate {
        for provider in options.candidates {
            try cancel.check()
            let candidate = try open(provider, cancel)
            let selected: Bool
            do {
                selected = try attempt(candidate, automatic: options.isAutomatic, log: log, cancel: cancel)
            } catch {
                try candidate.close()
                throw error
            }
            if selected {
                log?("DNS bağlantısı seçildi: " + provider.description)
                return candidate
            }
            // Completely closed before the next opens; a failure to close ends the selection.
            try candidate.close()
        }
        throw KitError.dnsSelectionFailed()
    }

    /// True when `candidate` is selected, false when it failed its check and the next one may be tried.
    private static func attempt(_ candidate: DnsCandidate, automatic: Bool, log: ((String) -> Void)?, cancel: Cancellation) throws -> Bool {
        try cancel.check()
        if automatic {
            log?("DNS erişim kontrolü: " + candidate.provider.description)
            do {
                try candidate.verify(cancel: cancel)
            } catch let failure as ConnectivityFailure {
                try cancel.check()
                guard !(failure.reason == .http && failure.httpStatus == 429), failure.reason != .canceled else { throw failure }
                log?("DNS erişim kontrolü: " + failure.message)
                return false
            }
        }
        try cancel.check()
        return true
    }
}
