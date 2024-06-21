# CassetteOverlay.jl

```julia
julia> using CassetteOverlay, Test

julia> @MethodTable sintable;

julia> @overlay sintable sin(x::Union{Float32,Float64}) = cos(x);

julia> pass = @overlaypass sintable;

# run with the overlayed method
julia> @test pass(42) do a
           sin(a) * cos(a)
       end == cos(42)^2
Test Passed

# invalidate the overlayed method and make it return `cos∘sin`
julia> @overlay sintable sin(x::Union{Float32,Float64}) = cos(x) * @nonoverlay sin(x);

julia> @test pass(42) do a
           sin(a) * cos(a)
       end == cos(42)^2 * sin(42)
Test Passed
```
