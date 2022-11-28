module math

using CassetteOverlay, Test

@MethodTable SinTable;

@overlay SinTable sin(x::Union{Float32,Float64}) = cos(x);

pass = @OverlayPass SinTable;

# Run overlayed methods
@test pass(42) do a
    sin(a) * cos(a)
end == cos(42)^2

@overlay SinTable sin(x::Union{Float32,Float64}) = 0.0

@test pass(42) do a
    sin(a) * cos(a)
end == 0.0

end # module math
