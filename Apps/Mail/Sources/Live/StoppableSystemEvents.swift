import OpenHumanSync

protocol StoppableSystemEvents: SystemEventsSource {
    func stop()
}
