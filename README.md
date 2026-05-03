# RettGame — Application iOS dédiée au jeu du regard

App standalone séparée de **RettApp**, qui se concentre exclusivement sur le jeu du
regard pour la communication par les yeux des enfants atteints du syndrome de Rett.

## Pourquoi une app séparée ?

L'app principale RettApp regroupe le suivi médical (crises, médicaments, observations,
rapports). Le jeu du regard a un public et un usage radicalement différents :

- **Public** : l'enfant lui-même, encadré par un adulte
- **UX** : plein écran, mode jeu, pas de menus
- **Capabilities** : caméra TrueDepth uniquement, pas d'iCloud, pas de HealthKit, pas
  de Sign in with Apple
- **Cycle de vie indépendant** : peut évoluer (nouveaux mini-jeux) sans toucher à RettApp

Mélanger les deux dans une même app rendait l'expérience confuse pour les deux types
d'utilisateurs.

## Fonctionnalités

- 🎯 Jeu de la « tarte à la crème » — l'enfant fixe un personnage, une tarte lui arrive
  dessus, gratification visuelle/sonore
- 📐 Suivi du regard via les blendShapes TrueDepth (Face ID)
- 🎚️ Calibration tap-based + filtre Kalman réglable depuis les Réglages

## Stack

- iOS 17+, SwiftUI, ARKit (`ARFaceTrackingConfiguration`)
- Aucune dépendance externe
- Pas de stockage médical, pas de SwiftData, pas de réseau
  (le seul UserDefaults stocke la calibration apprise localement)

## Générer le projet Xcode

```bash
ruby scripts/generate_rettgame_xcodeproj.rb
open RettGame.xcodeproj
```

## Bundle

| Champ | Valeur |
|---|---|
| Bundle ID | `fr.afsr.RettGame` |
| Nom App Store | RettGame |
| Catégorie | Medical / Health & Fitness |
| Version | 1.0.0 |
