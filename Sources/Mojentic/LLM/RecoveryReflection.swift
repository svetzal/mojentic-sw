/// Recovery reflection exposes safe metadata without traversing retained private evidence.
extension RecoveryFailure: CustomReflectable {
    /// Safe fields retain their exact values; use `inspectEvidence()` for private evidence.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "logicalID": logicalID, "identity": identity as Any, "provider": provider,
                "operation": operation, "category": category, "status": status as Any,
                "retryAfter": retryAfter, "progress": progress, "acceptance": acceptance,
                "phase": phase as Any, "eligible": eligible, "reason": reason,
                "providerCode": providerCode as Any, "providerRequestID": providerRequestID as Any,
            ], displayStyle: .struct)
    }
}

extension RecoveryEvidence: CustomReflectable {
    /// Only validated provider metadata is available through default reflection.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "providerCode": providerCode as Any, "providerRequestID": providerRequestID as Any,
            ], displayStyle: .struct)
    }
}

extension RecoveryError: CustomReflectable {
    /// Retains safe terminal fields and recursively safe failures and history.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "logicalID": logicalID, "outcome": outcome, "failure": failure, "history": history,
            ], displayStyle: .struct)
    }
}

extension CompletionRecoveryReport: CustomReflectable {
    /// Retains exact correlation, progress and recursively safe failure history.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "logicalID": logicalID, "identity": identity as Any, "progress": progress, "history": history,
            ], displayStyle: .struct)
    }
}

extension RecoveryWireEvent: CustomReflectable {
    /// Exposes the case, exact identity and received status without URL, headers or bytes.
    ///
    /// Pattern match the event explicitly to inspect sensitive associated values.
    public var customMirror: Mirror {
        switch self {
        case .request(let identity, _, _, _):
            return Mirror(self, children: ["kind": "request", "identity": identity], displayStyle: .enum)
        case .headers(let identity, let status, _):
            return Mirror(
                self,
                children: ["kind": "headers", "identity": identity, "status": status],
                displayStyle: .enum)
        case .body(let identity, _):
            return Mirror(self, children: ["kind": "body", "identity": identity], displayStyle: .enum)
        }
    }
}
