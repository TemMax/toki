import Foundation

/// How often to ask the status page how it is doing.
///
/// Two rates, because the value of a poll is not constant: while everything is healthy the
/// only thing a poll can discover is that an incident started, and a minute of latency on
/// that is invisible. While an incident is live the user is staring at the banner waiting for
/// it to change — so halve the interval to catch each update, and the resolution, quickly.
/// Both are cheap: a conditional GET that 304s transfers no body at all.
public enum StatusPollPlanner {
    /// 60 s while healthy, 30 s while an incident is live.
    public static func interval(after status: ServiceStatus) -> TimeInterval {
        status.isDisrupted ? 30 : 60
    }
}
