// A question a host login's ssh is waiting on, and whether it repeats one already answered.
struct SSHLoginQuestion: Equatable {
    let prompt: SSHLoginPrompt
    let isRetry: Bool
}
