import Foundation

public enum ContextBudgeter {
    public static func safetyMargin(contextTokens: Int) -> Int {
        Int((Double(contextTokens) * AIPolicy.safetyMarginFraction).rounded(.up))
    }

    public static func inputBudget(
        contextTokens: Int?, policyInputCap: Int?, fixedTokens: Int, reservedOutput: Int, shrink: Double = 1
    ) throws -> Int {
        var budget: Int
        if let contextTokens {
            let used = fixedTokens + reservedOutput + safetyMargin(contextTokens: contextTokens)
            guard contextTokens - used > 0 else {
                throw AIError.contextOverflow(counted: used, limit: contextTokens)
            }
            budget = contextTokens - used
            if let policyInputCap { budget = min(budget, policyInputCap) }
        } else if let policyInputCap {
            budget = policyInputCap
        } else {
            throw AIError.unavailable(.other("context size unknown"))
        }
        if shrink < 1 { budget = Int((Double(budget) * shrink).rounded(.down)) }
        guard budget > 0 else { throw AIError.contextOverflow(counted: fixedTokens + reservedOutput, limit: 0) }
        return budget
    }

    public static func inputBudget(
        _ capabilities: AICapabilities, fixedTokens: Int, reservedOutput: Int, shrink: Double = 1
    ) throws -> Int {
        try inputBudget(
            contextTokens: capabilities.contextTokens, policyInputCap: capabilities.policyInputCap,
            fixedTokens: fixedTokens, reservedOutput: reservedOutput, shrink: shrink)
    }
}
