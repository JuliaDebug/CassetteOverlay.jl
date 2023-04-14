module abstract

using CassetteOverlay, Test
@MethodTable SinTable
mutable struct CosCounter <: CassetteOverlay.AbstractBindingOverlay{@__MODULE__, :SinTable}
    ncos::Int
end

function (c::CosCounter)(::typeof(cos), args...)
    c.ncos += 1
    return cos(args...)
end

@overlay SinTable sin(x::Union{Float32,Float64}) = cos(x);

let pass! = CosCounter(0)
    pass!(42) do a
        sin(a) * cos(a)
    end
    @test pass!.ncos == 2
end

function sin_wo_cnt end
@overlay SinTable sin_wo_cnt(x) = @nonoverlay cos(x);

let pass! = CosCounter(0)
    pass!(42) do a
        sin_wo_cnt(a) * cos(a)
    end
    @test pass!.ncos == 1
end

end
