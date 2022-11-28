module simple

using CassetteOverlay, Test

@MethodTable SimpleTable;

pass = @OverlayPass SimpleTable

# Run overlayed methods
@overlay SimpleTable Base.identity(@nospecialize x) = 42;
@test pass(identity, nothing) == 42
@test pass() do
    identity(nothing)
end == 42

# method invalidation
@overlay SimpleTable Base.identity(@nospecialize x) = 0;
@test pass(identity, nothing) == 0

end
