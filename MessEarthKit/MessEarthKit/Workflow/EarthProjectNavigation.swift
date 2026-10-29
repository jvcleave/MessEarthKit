import Foundation
import Observation

enum EarthAppRoute: Hashable, Sendable
{
    case project(UUID), preview(UUID), settings
}

struct EarthNavigationTicket: Sendable
{
    let revision: UInt64
    let route: EarthAppRoute
}

/// A completion may advance only the route that initiated it. Leaving and
/// returning also invalidates the ticket; project work continues independently.
@MainActor
@Observable
final class EarthProjectNavigation
{
    var path: [EarthAppRoute] = []
    {
        didSet { if path != oldValue { revision &+= 1 } }
    }

    private var revision: UInt64 = 0

    func ticket(route: EarthAppRoute) -> EarthNavigationTicket? { path.last == route ? .init(revision: revision, route: route) : nil }

    @discardableResult
    func advance(_ ticket: EarthNavigationTicket?, to route: EarthAppRoute) -> Bool
    {
        guard let ticket, ticket.revision == revision, path.last == ticket.route else { return false }
        path.append(route)
        return true
    }
}
