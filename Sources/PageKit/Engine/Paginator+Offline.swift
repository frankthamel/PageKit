/// What the paginator does with network status. It never holds a request back because of
/// it, as the status can be wrong. It labels the list and picks up again on reconnecting.
extension Paginator {
    /// Follows the network for as long as the paginator lives.
    ///
    /// The reference is weak so the stream, which can stay silent for ever, can't keep an
    /// abandoned paginator alive. `deinit` ends the wait.
    func startListeningForConnectivity() {
        let updates = environment.connectivity.updates()
        connectivityTask = Task { [weak self] in
            for await status in updates {
                guard let self else { return }
                await connectivityChanged(to: status)
            }
        }
    }

    /// Takes in a new status. The work reconnecting starts runs separately, as a status
    /// that arrives during it must not wait.
    func connectivityChanged(to status: ConnectivityStatus) {
        guard !isCancelled else { return }
        let reconnected = isOffline && status.isOnline
        connectivityStatus = status
        if isOffline == status.isOnline {
            isOffline = !status.isOnline
            publish()
        }
        scheduleReadAhead()
        if reconnected {
            reconnectTask = Task { await resumeAfterReconnect() }
        }
    }

    /// Takes in what a failure says about the connection.
    func noteFailure(_ failure: PaginationError) {
        if failure == .offline { isOffline = true }
    }

    /// The network answered, which ends any offline that only a failure reported. Whatever
    /// the monitor said stands, because the monitor will say when that changes.
    func noteNetworkAnswered() {
        isOffline = connectivityStatus?.isOnline == false
    }

    /// Silently refreshes page 1 if the list goes no further, then retries what the list
    /// was waiting on. Past page 1 a refresh could shrink the list, so the items stay stale.
    private func resumeAfterReconnect() async {
        guard !isCancelled, configuration.cachePolicy != .cacheOnly, !state.isLoading else { return }
        guard !pageOrder.isEmpty else { return await retry() }
        let wasWaitingForNextPage = lastFailedOperation == .nextPage
        if pageOrder.count == 1 { await revalidateFirstPage() }
        guard wasWaitingForNextPage else { return }
        // A refresh that replaced the list took the failure with it. The footer still waits.
        if lastFailedOperation == .nextPage {
            await retry()
        } else {
            await loadNextPage()
        }
    }
}
