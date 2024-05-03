using Test, Suppressor
using Random: seed!

using JustRelax, JustRelax.JustRelax2D, JustRelax.DataIO
const backend_JR = CPUBackend

using ParallelStencil, ParallelStencil.FiniteDifferences2D
@init_parallel_stencil(Threads, Float64, 2) #or (CUDA, Float64, 2) or (AMDGPU, Float64, 2)

using JustPIC, JustPIC._2D
# Threads is the default backend,
# to run on a CUDA GPU load CUDA.jl (i.e. "using CUDA") at the beginning of the script,
# and to run on an AMD GPU load AMDGPU.jl (i.e. "using AMDGPU") at the beginning of the script.
const backend = CPUBackend # Options: CPUBackend, CUDABackend, AMDGPUBackend
# const backend = CUDABackend # Options: CPUBackend, CUDABackend, AMDGPUBackend

# Load script dependencies
using GeoParams

@testset "Test checkpointing" begin
    @suppress begin
    # Set up mock data
        # Physical domain ------------------------------------
        ly           = 1.0       # domain length in y
        lx           = 1.0       # domain length in x
        nx, ny       = 64, 64
        ni           = nx, ny     # number of cells
        igg          = IGG(init_global_grid(nx, ny, 1; init_MPI= true)...)
        li           = lx, ly     # domain length in x- and y-
        di           = @. li / ni # grid step in x- and -y
        origin       = 0.0, -ly   # origin coordinates (15km f sticky air layer)
        grid         = Geometry(ni, li; origin = origin)
        (; xci, xvi) = grid

        dst = "test_checkpoint"
        stokes  = StokesArrays(backend_JR, ni)
        thermal = ThermalArrays(backend_JR, ni)

        nxcell, max_xcell, min_xcell = 20, 32, 12
        particles = init_particles(
            backend, nxcell, max_xcell, min_xcell, xvi..., di..., ni...
        )
        # temperature
        pT, pPhases      = init_cell_arrays(particles, Val(3))
        time = 1.0

        stokes.viscosity.η .= fill(rand(seed!(1234)))
        stokes.V.Vy        .= fill(rand(seed!(1234)))
        thermal.T          .= fill(rand(seed!(1234)))


        # Call the function
        checkpointing_jld2(dst, stokes, thermal, particles, pPhases, time, igg)

        # Check that the file was created
        fname = joinpath(dst, "checkpoint_rank_$(igg.me).jld2")
        @test isfile(fname)

        # Load the data from the file
        load_checkpoint_jld2(fname)

        @test stokes.viscosity.η[1] ≈ 0.325977 rtol = 1e-4
        @test stokes.V.Vy[1] ≈ 0.325977 rtol = 1e-4
        @test thermal.T[1] ≈ 0.325977 rtol = 1e-4


        # check the if the hdf5 function also works
        checkpointing(dst, stokes, thermal.T, time)

        # Check that the file was created
        fname = joinpath(dst, "checkpoint.h5")
        @test isfile(fname)

        # Load the data from the file
        P, T, Vx, Vy, η, t = load_checkpoint(fname)

        stokes.viscosity.η  .= η
        stokes.V.Vy         .= Vy
        thermal.T           .= T
        @test stokes.viscosity.η[1] ≈ 0.325977 rtol = 1e-4
        @test stokes.V.Vy[1] ≈ 0.325977 rtol = 1e-4
        @test thermal.T[1] ≈ 0.325977 rtol = 1e-4


        # Remove the generated directory
        rm(dst, recursive=true)
    end
end
