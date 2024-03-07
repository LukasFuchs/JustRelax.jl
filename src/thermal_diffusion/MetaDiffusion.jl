function make_thermal_arrays!(ndim)
    flux_sym1 = (:qTx, :qTy, :qTz)
    flux_sym2 = (:qTx2, :qTy2, :qTz2)
    flux1 = [:($(flux_sym1[i])::_T) for i in 1:ndim]
    flux2 = [:($(flux_sym2[i])::_T) for i in 1:ndim]

    @eval begin
        struct ThermalArrays{_T}
            T::_T # Temperature @ grid nodes
            Tc::_T # Temperature @ cell centers
            ΔT::_T
            Told::_T
            dT_dt::_T
            $(flux1...)
            $(flux2...)
            H::_T # source terms
            shear_heating::_T # shear heating terms
            ResT::_T

            function ThermalArrays(ni::NTuple{1,Integer})
                nx, = ni
                T, ΔT, Told = @zeros(ni...), @zeros(ni...), @zeros(ni...)
                dT_dt = @zeros(nx - 2)
                qTx = @zeros(nx - 1)
                qTx2 = @zeros(nx - 1)
                ResT = @zeros(nx - 2)
                return new{typeof(T)}(T, ΔT, Told, dT_dt, qTx, qTx2, ResT)
            end

            function ThermalArrays(ni::NTuple{2,Integer})
                nx, ny = ni
                T = @zeros(nx + 3, ny + 1)
                ΔT = @zeros(nx + 3, ny + 1)
                Told = @zeros(nx + 3, ny + 1)
                Tc = @zeros(ni...)
                H = @zeros(ni...)
                shear_heating = @zeros(ni...)
                dT_dt = @zeros(nx + 1, ny - 1)
                qTx = @zeros(nx + 2, ny - 1)
                qTy = @zeros(nx + 1, ny)
                qTx2 = @zeros(nx + 2, ny - 1)
                qTy2 = @zeros(nx + 1, ny)
                ResT = @zeros(nx + 1, ny - 1)
                return new{typeof(T)}(
                    T, Tc, ΔT, Told, dT_dt, qTx, qTy, qTx2, qTy2, H, shear_heating, ResT
                )
            end

            function ThermalArrays(ni::NTuple{3,Integer})
                nx, ny, nz = ni
                T, ΔT, Told = @zeros(ni .+ 1...), @zeros(ni .+ 1...), @zeros(ni .+ 1...)
                Tc = @zeros(ni...)
                H = @zeros(ni...)
                shear_heating = @zeros(ni...)
                dT_dt = @zeros(ni .- 1)
                qTx = @zeros(nx, ny - 1, nz - 1)
                qTy = @zeros(nx - 1, ny, nz - 1)
                qTz = @zeros(nx - 1, ny - 1, nz)
                qTx2 = @zeros(nx, ny - 1, nz - 1)
                qTy2 = @zeros(nx - 1, ny, nz - 1)
                qTz2 = @zeros(nx - 1, ny - 1, nz)
                ResT = @zeros((ni .- 1)...)
                return new{typeof(T)}(
                    T,
                    Tc,
                    ΔT,
                    Told,
                    dT_dt,
                    qTx,
                    qTy,
                    qTz,
                    qTx2,
                    qTy2,
                    qTz2,
                    H,
                    shear_heating,
                    ResT,
                )
            end
        end
    end
end

function make_PTthermal_struct!()
    @eval begin
        struct PTThermalCoeffs{T,M,nDim}
            CFL::T
            ϵ::T
            max_lxyz::T
            max_lxyz2::T
            Vpdτ::T
            θr_dτ::M
            dτ_ρ::M

            function PTThermalCoeffs(
                K, ρCp, dt, di::NTuple{nDim,T}, li::NTuple{nDim,Any}; ϵ=1e-8, CFL=0.9 / √3
            ) where {nDim,T}
                Vpdτ = min(di...) * CFL
                max_lxyz = max(li...)
                max_lxyz2 = max_lxyz^2
                Re = @. π + √(π * π + ρCp * max_lxyz2 / K / dt) # Numerical Reynolds number
                θr_dτ = @. max_lxyz / Vpdτ / Re
                dτ_ρ = @. Vpdτ * max_lxyz / K / Re

                return new{eltype(Vpdτ),typeof(dτ_ρ),nDim}(
                    CFL, ϵ, max_lxyz, max_lxyz2, Vpdτ, θr_dτ, dτ_ρ
                )
            end

            function PTThermalCoeffs(
                CFL::T, ϵ::T, max_lxyz::T, Vpdτ::T, θr_dτ::M, dτ_ρ::M
            ) where {T,M}
                nDim = length(size(θr_dτ))
                return new{T,M,nDim}(CFL, ϵ, max_lxyz, max_lxyz^2, Vpdτ, θr_dτ, dτ_ρ)
            end
        end

        # with phase ratios
        function PTThermalCoeffs(
            rheology,
            phase_ratios,
            args,
            dt,
            ni,
            di::NTuple{nDim,T},
            li::NTuple{nDim,Any};
            ϵ=1e-8,
            CFL=0.9 / √3,
        ) where {nDim,T}
            Vpdτ = min(di...) * CFL
            max_lxyz = max(li...)
            θr_dτ, dτ_ρ = @zeros(ni...), @zeros(ni...)

            idx = ntuple(i -> 1:ni[i], Val(nDim))
            @parallel (idx) compute_pt_thermal_arrays!(
                θr_dτ, dτ_ρ, rheology, phase_ratios.center, args, max_lxyz, Vpdτ, inv(dt)
            )

            return PTThermalCoeffs(CFL, ϵ, max_lxyz, Vpdτ, θr_dτ, dτ_ρ)
        end

        # without phase ratios
        function PTThermalCoeffs(
            # function PTThermalCoeffs(
            rheology,
            args,
            dt,
            ni,
            di::NTuple{nDim,T},
            li::NTuple{nDim,Any};
            ϵ=1e-8,
            CFL=0.9 / √3,
        ) where {nDim,T}
            Vpdτ = min(di...) * CFL
            max_lxyz = max(li...)
            θr_dτ, dτ_ρ = @zeros(ni...), @zeros(ni...)

            idx = ntuple(i -> 1:ni[i], Val(nDim))
            @parallel (idx) compute_pt_thermal_arrays!(
                θr_dτ, dτ_ρ, rheology, args, max_lxyz, Vpdτ, inv(dt)
            )

            return PTThermalCoeffs(CFL, ϵ, max_lxyz, Vpdτ, θr_dτ, dτ_ρ)
        end

        @parallel_indices (I...) function compute_pt_thermal_arrays!(
            θr_dτ::AbstractArray, dτ_ρ, rheology, phase, args, max_lxyz, Vpdτ, _dt
        )
            _compute_pt_thermal_arrays!(
                θr_dτ, dτ_ρ, rheology, phase, args, max_lxyz, Vpdτ, _dt, I...
            )

            return nothing
        end

        @parallel_indices (I...) function compute_pt_thermal_arrays!(
            θr_dτ::AbstractArray, dτ_ρ, rheology, args, max_lxyz, Vpdτ, _dt
        )
            _compute_pt_thermal_arrays!(
                θr_dτ, dτ_ρ, rheology, args, max_lxyz, Vpdτ, _dt, I...
            )

            return nothing
        end

        function _compute_pt_thermal_arrays!(
            θr_dτ, dτ_ρ, rheology, phase, args, max_lxyz, Vpdτ, _dt, Idx::Vararg{Int,N}
        ) where {N}
            args_ij = (; T=args.T[Idx...], P=args.P[Idx...])
            phase_ij = phase[Idx...]
            ρCp = compute_ρCp(rheology, phase_ij, args_ij)
            _K = inv(fn_ratio(compute_conductivity, rheology, phase_ij, args_ij))

            _Re = inv(π + √(π * π + ρCp * max_lxyz^2 * _K * _dt)) # Numerical Reynolds number
            θr_dτ[Idx...] = max_lxyz / Vpdτ * _Re
            dτ_ρ[Idx...] = Vpdτ * max_lxyz * _K * _Re

            return nothing
        end

        function _compute_pt_thermal_arrays!(
            θr_dτ, dτ_ρ, rheology, args, max_lxyz, Vpdτ, _dt, Idx::Vararg{Int,N}
        ) where {N}
            args_ij = (; T=args.T[Idx...], P=args.P[Idx...])

            ρCp = compute_ρCp(rheology, args_ij)
            _K = inv(compute_conductivity(rheology, args_ij))

            _Re = inv(π + √(π * π + ρCp * max_lxyz^2 * _K * _dt)) # Numerical Reynolds number
            θr_dτ[Idx...] = max_lxyz / Vpdτ * _Re
            dτ_ρ[Idx...] = Vpdτ * max_lxyz * _K * _Re

            return nothing
        end
    end
end
