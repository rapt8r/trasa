# Trasa

Aplikacja iOS (SwiftUI, iOS 17+) zapisująca trasę przejazdu autem: GPS, prędkość, znacznik czasu, wysokość, kurs, dokładność.
Mapa na żywo, lista tras, szczegóły trasy z mapą, statystykami i wykresami, eksport GPX.

## Budowanie

**Na Macu:** `brew install xcodegen && xcodegen generate && open Trasa.xcodeproj`, wybierz swój Team w Signing i uruchom na telefonie.

**Bez Maca (Windows):** wypchnij repo na GitHub. Workflow `build` zbuduje niepodpisany `Trasa.ipa` (artefakt w zakładce Actions).
Zainstaluj go przez [Sideloadly](https://sideloadly.io) lub AltStore z darmowym Apple ID (podpis trzeba odnawiać co 7 dni).

## Dane

Każda trasa to plik `trip-<unix>.jsonl` w Dokumentach aplikacji (widoczny w aplikacji Pliki), jeden punkt GPS na linię,
dopisywany na bieżąco, więc przerwanie działania aplikacji nie kasuje nagranej części.

## Test logiki

`swiftc -swift-version 5 Sources/TripCore.swift Tests/main.swift -o check && ./check`
