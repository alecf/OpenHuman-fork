import OpenHumanSync

public protocol StoppableSystemEvents: SystemEventsSource {
    func stop()
}
