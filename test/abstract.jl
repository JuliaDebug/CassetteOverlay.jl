module abstract

using CassetteOverlay, Test
import Base: cos

@MethodTable SinTable
mutable struct CosCounter <: AbstractBindingOverlay{@__MODULE__, :SinTable}
    ncos::Int
end

@overlay SinTable function Base.cos(x::Union{Float32,Float64})
    getpass().ncos += 1
    return @nonoverlay cos(x)
end

let pass! = CosCounter(0)
    x = 42
    @test pass!() do
        sin(x) * cos(x)
    end == sin(x) * cos(x)
    @test pass!.ncos == 1
end

end
