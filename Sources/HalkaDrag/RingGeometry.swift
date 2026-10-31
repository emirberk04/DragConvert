import Foundation

/// Halkanın dilim geometrisi.
///
/// Açılar saat yönünde, 0° saat 12'de; ilk dilim tepede ortalanır. Vektörler y yukarı (AppKit görünüm
/// koordinatı). İç yarıçapın içi ölü bölge: orada bırakmak iptal demek.
public struct RingGeometry: Sendable, Equatable {
    public var innerRadius: Double
    public var outerRadius: Double
    /// Dilimler arasındaki boşluk (sadece çizim; seçimde boşluk yok, her yön bir dilime düşer).
    public var gapDegrees: Double

    public init(innerRadius: Double = 46, outerRadius: Double = 136, gapDegrees: Double = 2) {
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.gapDegrees = gapDegrees
    }

    /// Merkezden imlece vektörün hangi dilime düştüğü. Ölü bölgede veya dilim yoksa `nil`.
    /// Dış yarıçapın dışı da en yakın dilimi seçer: hedefi tutturmak için nişan almak gerekmesin.
    public func index(dx: Double, dy: Double, count: Int) -> Int? {
        guard count > 0, (dx * dx + dy * dy).squareRoot() >= innerRadius else { return nil }
        let step = 360.0 / Double(count)
        let angle = Self.normalized(atan2(dx, dy) * 180 / .pi)
        return Int(Self.normalized(angle + step / 2) / step) % count
    }

    /// Dilimin başlangıç ve bitiş açısı (derece, saat yönünde, tepeden).
    public func span(of index: Int, count: Int) -> (start: Double, end: Double) {
        let step = 360.0 / Double(count)
        let mid = Double(index) * step
        let gap = count > 1 ? gapDegrees / 2 : 0
        return (mid - step / 2 + gap, mid + step / 2 - gap)
    }

    /// Dilimin ortası; etiket ve simge buraya çizilir. Y yukarı.
    public func center(of index: Int, count: Int) -> (x: Double, y: Double) {
        let angle = Double(index) * 360.0 / Double(count) * .pi / 180
        let radius = (innerRadius + outerRadius) / 2
        return (radius * sin(angle), radius * cos(angle))
    }

    static func normalized(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }
}
