module return_type

using CassetteOverlay, Test

@MethodTable ReturnTypeTable

pass = @overlaypass ReturnTypeTable

@test pass(sin, 1) do f, args...
    tt = Base.signature_type(f, Any[Core.Typeof(a) for a = args])
    T = Core.Compiler.return_type(tt)
    T[]
end == Float64[]

end # module return_type
