using Test

# @testset "CassetteOverlay.jl" begin
#     @testset "simple" include("simple.jl")
#     @testset "math" include("math.jl")
#     @testset "misc" include("misc.jl")
# end

using CassetteOverlay, Test

@MethodTable SinTable;

@overlay SinTable sin(x::Union{Float32,Float64}) = cos(x);

struct SinPass <: OverlayPass end

CassetteOverlay.method_table(::Type{SinPass}) = SinTable

pass = SinPass();

# run with the overlayed method
@test pass(42) do a
    sin(a) * cos(a)
end == cos(42)^2

# invalidate the overlayed method and make it return `cos∘sin`
@overlay SinTable sin(x::Union{Float32,Float64}) = cos(x) * @nonoverlay sin(x);

@test pass(42) do a
    sin(a) * cos(a)
end == cos(42)^2 * sin(42)
