module misc

using CassetteOverlay, Test

@MethodTable misc_table
pass = @overlaypass misc_table

# Issue #9 – Core.Compiler.return_type needs a special casing
function strange_sin end

@overlay misc_table strange_sin(x) = sin(x);
@test pass(strange_sin, 1) do f, args...
    tt = Base.signature_type(f, Any[Core.Typeof(a) for a = args])
    return Core.Compiler.return_type(tt)
end == Float64
@test pass(1) do args...
    tt = Tuple{Any[Core.Typeof(a) for a = args]...}
    return Core.Compiler.return_type(strange_sin, tt)
end == Float64

@overlay misc_table strange_sin(x) = 0;
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

# re-raise code generation error
@generated function codegen_error(a)
    if a <: Number
        return :(sin(a))
    end
    error("Bad argument type")
end
@test pass(42) do a
    codegen_error(a)
end == sin(42)
@test_throws "Bad argument type" pass("42") do a
    codegen_error(a)
end

@test isa(pass(pointer, Int[1]), Ptr{Int})

# https://github.com/JuliaLang/julia/issues/50452
@eval sparam_isdefined() = $(Expr(:isdefined, Expr(:static_parameter, 1)))
@eval function sparam_isdefined(a::T) where T
    return $(Expr(:isdefined, Expr(:static_parameter, 1)))
end
@test !pass(sparam_isdefined)
@test pass(sparam_isdefined, 42)

if isdefined(Base, :ScopedValues)
    const sval = Base.ScopedValue(1)
    @test pass() do
        Base.with(sval => 2) do
            sval[]
        end
    end == 2
end

# https://github.com/JuliaDebug/CassetteOverlay.jl/issues/41
# `ccall` with a function pointer
const jl_gensym_ptr = cglobal(:jl_gensym)
issue41() = @ccall $jl_gensym_ptr()::Ref{Symbol}
@test pass(issue41) isa Symbol

end
