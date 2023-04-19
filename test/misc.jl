module misc

using CassetteOverlay, Test

@MethodTable MiscTable
pass = @overlaypass MiscTable

# Issue #9 – Core.Compiler.return_type needs a special casing
function strange_sin end

@overlay MiscTable strange_sin(x) = sin(x);
@test pass(strange_sin, 1) do f, args...
    tt = Base.signature_type(f, Any[Core.Typeof(a) for a = args])
    return Core.Compiler.return_type(tt)
end == Float64
@test pass(1) do args...
    tt = Tuple{Any[Core.Typeof(a) for a = args]...}
    return Core.Compiler.return_type(strange_sin, tt)
end == Float64

@overlay MiscTable strange_sin(x) = 0;
@test pass(strange_sin, 1) do f, args...
    tt = Base.signature_type(f, Any[Core.Typeof(a) for a = args])
    return Core.Compiler.return_type(tt)
end == Int
@test pass(1) do args...
    tt = Tuple{Any[Core.Typeof(a) for a = args]...}
    return Core.Compiler.return_type(strange_sin, tt)
end == Int

# Issue #14 - :foreigncall first argument mapping
using NaNMath
@test pass(NaNMath.sin, 1.0) === NaNMath.sin(1.0)

# Issue #16 – give a proper method error
@test_throws "MethodError: no method matching sin(::String)" pass() do
    sin("1")
end

@test isa(pass(pointer, Int[1]), Ptr{Int})

end
