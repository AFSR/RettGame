import Foundation

/// Adresses externes de l'association. Ces liens s'ouvrent dans le navigateur : l'app elle-même
/// ne se connecte à aucun serveur.
enum AFSRLinks {
    static let website = URL(string: "https://afsr.fr")!
    static let donation = URL(string: "https://afsr.fr/nous-soutenir/faire-un-don")!
}
