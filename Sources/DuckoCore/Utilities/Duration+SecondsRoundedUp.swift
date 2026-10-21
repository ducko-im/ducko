public extension Duration {
    /// The duration in whole seconds, counting a started second as a whole one, and `Int.max` for one longer than that.
    var secondsRoundedUp: Int {
        let (seconds, attoseconds) = attoseconds.quotientAndRemainder(dividingBy: 1_000_000_000_000_000_000)
        return Int(clamping: seconds + (attoseconds > 0 ? 1 : 0))
    }
}
