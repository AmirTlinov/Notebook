#if !canImport(simd)

// SIMD storage is part of Swift. These operations supply the same vector
// algebra when Apple's simd module is unavailable, including WebAssembly.
func dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.x + a.y * b.y }
func normalize(_ value: SIMD2<Float>) -> SIMD2<Float> { value / dot(value, value).squareRoot() }
func simd_dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { dot(a, b) }
func simd_length_squared(_ value: SIMD2<Float>) -> Float { dot(value, value) }
func simd_length(_ value: SIMD2<Float>) -> Float { dot(value, value).squareRoot() }
func simd_abs(_ value: SIMD2<Float>) -> SIMD2<Float> { .init(abs(value.x), abs(value.y)) }
func simd_min(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> { .init(min(a.x, b.x), min(a.y, b.y)) }
func simd_max(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> { .init(max(a.x, b.x), max(a.y, b.y)) }
#endif
