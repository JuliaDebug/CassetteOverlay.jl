module misc

using CassetteOverlay, NaNMath, Test

@MethodTable MiscTable
pass = @overlaypass MiscTable

# Issue #14 - :foreigncall first argument mapping
@test pass(NaNMath.sin, 1.0) === NaNMath.sin(1.0)

end
