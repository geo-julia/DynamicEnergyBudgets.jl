"""
    assimilation!(o, u)
Runs assimilation methods, depending on formulation and state.
"""
assimilation!(organs::Tuple, u) = apply(assimilation!, organs, u)
assimilation!(o::Organ, u) = assimilation!(o.params.assimilation, o, u)
assimilation!(::Void, o::Organ, u) = nothing

"""
    assimilation!(f::AbstractAassim, o, u)
Runs nitrogen uptake, and combines N with translocated C.
"""
function assimilation!(f::AbstractCAssim, o, u)
    germinated(u[V], o.params.M_Vgerm) || return nothing

    J1_EC_ass = photosynthesis(f, o, u)

    o.J[C,ass] = J1_EC_ass
    # Merge rejected N from root and photosynthesized C into reserves
    (o.J[C,ass], o.J[N,tra], o.J[E,ass], lossC, lossN) =
        stoich_merge(J1_EC_ass, o.J[N,tra], o.shared.y_E_CH_NO, o.shared.y_E_EN)
    o.J[C,los] += lossC; o.J[N,los] += lossN

    return nothing
end

"""
    assimilation!(f::AbstractNH4_NO3Assim, o, u)
Runs nitrogen uptake for nitrate and ammonia, and combines N with translocated C.
Unused ammonia is discarded.
"""
function assimilation!(f::AbstractNH4_NO3Assim, o, u)
    germinated(u[V], o.params.M_Vgerm) || return nothing

    (J_N_ass, J_NO_ass, J_NH_ass) = uptake_nitrogen(f, o, u)

    θNH = J_NH_ass/J_N_ass                          # Fraction of ammonia in arriving N-flux
    θNO = 1 - θNH                                   # Fraction of nitrate in arriving N-flux
    y_E_CH = θNH * f.y_E_CH_NH + θNO * o.shared.y_E_CH_NO  # Yield coefficient from C-reserve to reserve

    # Merge rejected C from shoot and uptaken N into reserves
    (o.J[C,tra], o.J[N,ass], o.J[E,ass], lossC, lossN) =
        stoich_merge(o.J[C,tra], J_N_ass, y_E_CH, 1/o.shared.n_N_E)
    # o.J[C,los] += lossC; o.J[N,los] += lossN

    # Unused NH₄ remainder is lost so we recalculate N assimilation for NO₃ only
    o.J[N,ass] = (J_NO_ass - θNO * o.shared.n_N_E * o.J[E,ass]) * 1/o.shared.n_N_EN
    return nothing
end

"""
    assimilation!(f::AbstractNAssim, o, u)
Runs nitrogen uptake, and combines N with translocated C.
"""
function assimilation!(f::AbstractNAssim, o, u)
    germinated(u[V], o.params.M_Vgerm) || return nothing

    J_N_assim = uptake_nitrogen(f, o, u)

    # This was not in the orignal model, but is needed to balance C. N reserve is part C
    # but incoming N is just N. C was being generated from nowhere, 
    # specifically in the N returned to N reserves by the synthesizing unit.
    # TODO: could this end up with a negative C reserve overall?
    # o.J[C,ass] += -J_N_assim / o.shared.n_N_N

    # Merge rejected C from shoot and uptaken N into reserves
    # treating N as N reserve now carbon has been incorporated.
    (o.J[C,tra], o.J[N,ass], o.J[E,ass], lossC, lossN) =
        stoich_merge(o.J[C,tra], J_N_assim, o.shared.y_E_CH_NO, o.shared.y_E_CH_NO)
    o.J[C,los] += lossC; o.J[N,los] += lossN

    return nothing
end

"""
    photosynthesis(f::ConstantCAssim, o, u)
Returns a constant rate of carbon assimilation.
"""
photosynthesis(f::ConstantCAssim, o, u) =
    f.uptake * u[V] * scale(o.vars)

"""
    photosynthesis(f::FvCBPhotosynthesis, o, u)
Returns carbon assimilated in mols per time.
"""
photosynthesis(f::FvCBPhotosynthesis, o, u) =
    o.vars.assimilation.aleaf * f.SLA * o.shared.w_V * u[V]

"""
    photosynthesis(f::KooijmanSLAPhotosynthesis, o, u)
Returns carbon assimilated in mols per time.
"""
function photosynthesis(f::KooijmanSLAPhotosynthesis, o, u)
    v = o.vars; va = assimilation(v)
    mass_area_coef = o.shared.w_V * f.SLA
    j1_l = half_saturation(f.j_L_Amax, f.J_L_K, va.J_L_F) * mass_area_coef
    j1_c = half_saturation(f.j_C_Amax, f.K_C, va.X_C) * mass_area_coef
    j1_o = half_saturation(f.j_O_Amax, f.K_O, va.X_O) * mass_area_coef

    # photorespiration.
    bound_o = j1_o/f.k_O_binding # mol/mol
    bound_c = j1_c/f.k_C_binding # mol/mol

    # c flux
    j_c_intake = (j1_c - j1_o)
    j1_co = j1_c + j1_o
    co_l = j1_co/j1_l - j1_co/ (j1_l + j1_co)
    # dimless

    j_c_intake / (1 + bound_c + bound_o + co_l) * u[V] * scale(v)
end

"""
    uptake_nitrogen(f::ConstantNAssim, o, u)
Returns constant nitrogen assimilation.
"""
uptake_nitrogen(f::ConstantNAssim, o, u) = f.uptake * u[V] * scale(o.vars)

"""
    uptake_nitrogen(f::KooijmanNH4_NO3Assim, o, u)
Returns total nitrogen, nitrate and ammonia assimilated in mols per time.
"""
function uptake_nitrogen(f::KooijmanNH4_NO3Assim, o, u)
    p = o.params; v = o.vars; va = assimilation(v)

    K1_NH = half_saturation(f.K_NH, f.K_H * scale(v), va.X_H) # Ammonia saturation. va.X_H was multiplied by ox.scaling. But that makes no sense.
    K1_NO = half_saturation(f.K_NO, f.K_H * scale(v), va.X_H) # Nitrate saturation
    J1_NH_ass = u[V] * scale(v) * half_saturation(f.j_NH_Amax, K1_NH, va.X_NH) # Arriving ammonia mols.mol⁻¹.s⁻¹
    J_NO_ass = u[V] * scale(v) * half_saturation(f.j_NO_Amax, K1_NO, va.X_NO) # Arriving nitrate mols.mol⁻¹.s⁻¹

    J_N_ass = J1_NH_ass + f.ρNO * J_NO_ass # Total arriving N flux
    return (J_N_ass, J_NO_ass, J1_NH_ass)
end

"""
    uptake_nitrogen(f::NAssim, o, u)
Returns nitrogen assimilated in mols per time.
"""
function uptake_nitrogen(f::NAssim, o, u)
    v = o.vars; va = assimilation(v)
    # Ammonia proportion in soil water
    K1_N = half_saturation(f.K_N, f.K_H * scale(v), va.X_H)
    # Arriving ammonia in mol mol^-1 s^-1
    u[V] * scale(v) * half_saturation(f.j_N_Amax, K1_N, va.X_NO)
end

