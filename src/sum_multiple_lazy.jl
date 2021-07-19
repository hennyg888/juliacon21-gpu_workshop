using CUDA

function reduce_grid_atomic_shmem(op, a::AbstractArray{T}, b) where {T}
    threads = blockDim().x
    thread = threadIdx().x
    block = blockIdx().x
    offset = (block-1) * threads

    # shared mem to buffer memory loads
    shared = @cuStaticSharedMem(T, (1024,))
    @inbounds shared[thread] = a[offset+thread]

    # parallel reduction of values in a block
    d = 1
    while d < threads
        sync_threads()
        index = 2 * d * (thread-1) + 1
        @inbounds if index <= threads
            shared[index] = op(shared[index], shared[index+d])
        end
        d *= 2
    end

    # atomic reduction
    if thread == 1
        @atomic b[] = op(b[], shared[1])
    end

    return
end

function my_sum_lazy(a::AbstractArray{T}, b::CuArray) where {T}
    kernel = @cuda launch=false reduce_grid_atomic_shmem(+, a, b)

    config = launch_configuration(kernel.fun)
    threads = min(config.threads, length(a))
    blocks = cld(length(a), threads)

    @cuda threads=threads blocks=blocks reduce_grid_atomic_shmem(+, a, b)
end

function my_multiple_sums_lazy(a::AbstractArray{T}) where {T}
    n = size(a)[end]
    dims = [axes(a)...][begin:end-1]
    sums = CuVector{T}(undef, n)
    for x in 1:size(a,3)
        y = view(a, dims..., x)
        my_sum_lazy(y, view(sums, x))
    end
    Array(sums)
end

function main()
    a = CUDA.rand(1024, 1024, 10)
    my_multiple_sums_lazy(a)

    CUDA.@profile begin
        my_multiple_sums_lazy(a)
        my_multiple_sums_lazy(a)
    end
end

isinteractive() || main()