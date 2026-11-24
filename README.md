# Journey

Aplikacja iOS (SwiftUI, iOS 17+) zapisująca trasę przejazdu autem: GPS, prędkość, znacznik czasu, wysokość, kurs, dokładność.
Mapa na żywo, lista tras, szczegóły trasy z mapą, statystykami i wykresami, eksport GPX.

## Budowanie

**Na Macu:** `brew install xcodegen && xcodegen generate && open Trasa.xcodeproj`, wybierz swój Team w Signing i uruchom na telefonie.

**Bez Maca (Windows):** wypchnij repo na GitHub. Workflow `build` zbuduje niepodpisany `Journey.ipa` (artefakt w zakładce Actions).
Zainstaluj go przez [Sideloadly](https://sideloadly.io) lub AltStore z darmowym Apple ID (podpis trzeba odnawiać co 7 dni).

## Dane

Każda trasa to plik `trip-<unix>.jsonl` w prywatnym katalogu aplikacji (niewidoczny w aplikacji Pliki), jeden punkt GPS na linię,
dopisywany na bieżąco, więc przerwanie działania aplikacji nie kasuje nagranej części. Plik trasy opuszcza telefon tylko przez eksport GPX/CSV.

## Połączenia sieciowe

- **Mapy Apple**: kafelki mapy, natężenie ruchu i nazwa ulicy (geokoder Apple, najwyżej raz na 20 s).
  Nazwy miejsc na liście tras: początek i koniec trasy zaokrąglone do ok. 1 km, raz na trasę;
  wyłączane w Ustawieniach, kasowane razem z trasą.
- **OpenStreetMap (Overpass API)**: ograniczenia prędkości. Aplikacja pobiera drogi dla całego kwadratu mapy
  (ok. 2 x 3 km) i trzyma go w pamięci podręcznej 30 dni, więc serwer widzi kolejne kwadraty i adres IP,
  a nie dokładną pozycję. Wyłączane w Ustawieniach ("Znaki ograniczeń prędkości").

## Test logiki

`swiftc -swift-version 5 Sources/TripCore.swift Sources/OBDCore.swift Tests/main.swift -o check && ./check`

## Samochód (OBD)

Ekran "Samochód" łączy się przez Bluetooth LE z adapterem zgodnym z ELM327 w gnieździe OBD.
Aplikacja pyta auto, które parametry obsługuje, i tylko je odczytuje. Niczego w aucie nie zmienia
i nie kasuje kodów błędów. Dziennik połączenia zostaje w telefonie, dopóki użytkownik sam go nie wyśle.

Raz połączony adapter jest zapamiętany i łączy się sam, gdy aplikacja jest w użyciu ("Rozłącz" to wyłącza).
Podczas nagrywania wartości z auta są dopisywane do punktów GPS w pliku trasy (pole `car`, klucz to numer
parametru OBD). Zapisywane są surowe wartości; paliwo liczy się z nich przy wyświetlaniu: z parametru
"zużycie paliwa" (0x5E), a gdy auto go nie podaje, z przepływu powietrza (MAF, benzyna 14,7:1, 745 g/l).
Odcinki bez danych auta dolicza szacunek z Ustawień. Korekta spalania w Ustawieniach mnoży wynik z auta.
