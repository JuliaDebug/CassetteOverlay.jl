module CassetteOverlay

function __init__()
    @warn """
CassetteOverlay cannot be used on Julia $(Base.VERSION).
If you're depending on CassetteOverlay, it may be best to avoid loading the package except on supported versions of Julia, for example:

    @static if Base.VERSION >= v"1.8"
        using CassetteOverlay
    end
    """
end

end # module CassetteOverlay
