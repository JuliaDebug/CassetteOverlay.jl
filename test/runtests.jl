using Test

@testset "CassetteOverlay.jl" begin
    @testset "simple" include("simple.jl")
    @testset "math" include("math.jl")
    @testset "misc" include("misc.jl")
    @static if VERSION >= v"1.10.0-DEV.90"
        # This interface depends on julia#47749
        @testset "abstract" include("abstract.jl")
    end
end
