# CassetteOverlay.jl

```julia
julia> using CassetteOverlay, Test

julia> @MethodTable SinTable;

julia> @overlay SinTable sin(x::Union{Float32,Float64}) = cos(x);

julia> pass = @OverlayPass SinTable;

# Run overlayed methods
julia> @test pass(42) do a
           sin(a) * cos(a)
       end == cos(42)^2
Test Passed

julia> @overlay SinTable sin(x::Union{Float32,Float64}) = 0.0

julia> @test pass(42) do a
           sin(a) * cos(a)
       end == 0.0
Test Passed
```
