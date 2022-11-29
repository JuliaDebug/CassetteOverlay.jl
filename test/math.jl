module math

using CassetteOverlay, Test

@MethodTable SinTable;

@overlay SinTable sin(x::Union{Float32,Float64}) = cos(x);

pass = @OverlayPass SinTable;

# run with the overlayed method
@test pass(42) do a
    sin(a) * cos(a)
end == cos(42)^2

# invalidate the overlayed method and make it return `cos∘sin`
@overlay SinTable sin(x::Union{Float32,Float64}) = cos(x)*nooverlay(sin, x);

@test pass(42) do a
    sin(a) * cos(a)
end == cos(42)^2 * sin(42)
       
end # module math
