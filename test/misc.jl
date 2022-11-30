module misc

using CassetteOverlay, Test

@MethodTable MiscTable
pass = @overlaypass MiscTable

# Issue #9 – Core.Compiler.return_type needs a special casing
@test pass(sin, 1) do f, args...
    tt = Base.signature_type(f, Any[Core.Typeof(a) for a = args])
    T = Core.Compiler.return_type(tt)
    T[]
end == Float64[]

# Issue #14 - :foreigncall first argument mapping
using NaNMath
@test pass(NaNMath.sin, 1.0) === NaNMath.sin(1.0)

end
