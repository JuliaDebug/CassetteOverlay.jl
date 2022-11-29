# CassetteOverlay.jl

```julia
julia> using CassetteOverlay, Test

julia> @MethodTable SinTable;

julia> @overlay SinTable sin(x::Union{Float32,Float64}) = cos(x);

julia> pass = @OverlayPass SinTable;

# run with the overlayed method
julia> @test pass(42) do a
           sin(a) * cos(a)
       end == cos(42)^2
Test Passed

# invalidate the overlayed method and make it return `cos∘sin`
julia> @overlay SinTable sin(x::Union{Float32,Float64}) = cos(x)*nooverlay(sin, x);

julia> @test pass(42) do a
           sin(a) * cos(a)
       end == cos(42)^2 * sin(42)
Test Passed
```
