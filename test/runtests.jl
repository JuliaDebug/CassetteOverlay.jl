using Test

@testset "CassetteOverlay.jl" begin
    @testset "simple" include("simple.jl")
    @testset "math" include("math.jl")
    @testset "Core.Compiler.return_type" include("return_type.jl")
end
