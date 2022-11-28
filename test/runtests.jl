using Test

@testset "CassetteOverlay.jl" begin
    @testset "simple" include("simple.jl")
    # @testset "math" include("math.jl")
end
