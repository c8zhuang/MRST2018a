function [state, report] = implicitTransport(state, G, tf, ...
                                             rock, fluid, varargin)
%Implicit single-point upstream mobility-weighted transport solver for two-phase flow.
%
% SYNOPSIS:
%   state = implicitTransport(state, G, tf, rock, fluid)
%   state = implicitTransport(state, G, tf, rock, fluid, 'pn1', pv1, ...)
%
% DESCRIPTION:
%   Implicit discretization of the transport equation
%
%      s_t + div[f(s)(v + mo K((rho_w-rho_o)g + grad(P_c)))] = f(s)q
%
%   where v is the sum of the phase Darcy fluxes, f is the fractional
%   flow function,
%
%                  mw(s)
%        f(s) = -------------
%               mw(s) + mo(s)
%
%   mi = kr_i/mu_i is the phase mobility of phase i, mu_i and rho_i are the
%   phase viscosity and density, respectively, g the (vector) acceleration
%   of gravity, K the permeability, and P_c(s) the capillary pressure.  The
%   source term f(s)q is a volumetric rate of water.
%
%   We use a first-order upstream mobility-weighted discretization in space
%   and a backward Euler discretization in time.  The transport equation is
%   solved on the time interval [0,tf] by calling the private function
%   'twophaseJacobian' to build functions computing the residual and the
%   Jacobian matrix of the discrete system in addition to a function taking
%   care of the update of the solution during a Newton-Raphson iteration.
%   These functions are passed to the private function 'newtonRaphson2ph'
%   that implements a Newton-Raphson iteration with some logic to modify
%   time step size in case of non-convergence.
%
% REQUIRED PARAMETERS:
%   state - Reservoir and well solution structure either properly
%           initialized from function 'initState', or the results from a
%           previous call to function 'solveIncompFlow' and, possibly, a
%           transport solver such as function 'implicitTransport'.
%
%   G     - Grid data structure discretizing the reservoir model.
%
%   tf    - End point of time integration interval (i.e., final time).
%           Measured in units of seconds.
%
%   rock  - Rock data structure.  Must contain the field 'rock.poro' and,
%           in the presence of gravity or capillary forces, valid
%           permeabilities measured in units of m^2 in field 'rock.perm'.
%
%   fluid - Fluid data structure as described by 'fluid_structure'.
%
% OPTIONAL PARAMETERS:
%
%   verbose  - Whether or not time integration progress should be
%              reported to the screen. Default value: verbose = mrstVerbose.
%
%   wells    - Well structure as defined by function 'addWell'.  May be
%              empty (i.e., W = []) which is interpreted as a model without
%              any wells.
%
%   bc       - Boundary condition structure as defined by function
%              'addBC'. This structure accounts for all external boundary
%              contributions to the reservoir flow.
%              Default value: bc = [] meaning all external no-flow
%              (homogeneous Neumann) conditions.
%
%   src      - Explicit source contributions as defined by function
%              'addSource'. Default value: src = [] meaning no explicit
%              sources exist in the model.
%
%   Trans    - two point flux transmissibilities. This will be used instead
%              of rock. Useful for grids without proper geometry and
%              or for getting consistency with pressure solver.
%
%   nltol    - Absolute tolerance of iteration.  The numerical solution
%              must satisfy the condition
%
%                 NORM(S-S0 + dt/porvol(out - in) - Q, INF) <= nltol
%
%              at all times in the interval [0,tf].
%              Default value: nltol = 1.0e-6.
%
%   lstrials - Maximum number of trials in line search method.  Each new
%              trial corresponds to halving the step size along the
%              search direction. Default value: lstrials = 20.
%
%   maxnewt  - Maximum number of inner iterations in Newton-Raphson method.
%              Default value: maxnewt = 25.
%
%   tsref    - Maximum time step refinement power.  The minimum time step
%              allowed is tf / 2^tsref.
%              Default value: tsref = 12.
%
%   LinSolve - Handle to linear system solver software to which the fully
%              assembled system of linear equations will be passed.
%              Assumed to support the syntax
%
%                        x = LinSolve(A, b)
%
%              in order to solve a system Ax=b of linear equations.
%              Default value: LinSolve = @mldivide (backslash).
%
%   gravity   - The current gravity in vector form. Defaults to gravity().
%
% RETURNS:
%   state - Updated reservoir/well solution object.
%           New values for reservoir saturations, state.s.
%
% EXAMPLE:
%   See simple2phWellExample.
%
% SEE ALSO:
%   `explicitTransport`, `private/twophaseJacobian`, `private/newtonRaphson2ph`.

%{
Copyright 2009-2018 SINTEF ICT, Applied Mathematics.

This file is part of The MATLAB Reservoir Simulation Toolbox (MRST).

MRST is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

MRST is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with MRST.  If not, see <http://www.gnu.org/licenses/>.
%}


   opt  = struct(...
      'verbose' ,         mrstVerbose,  ...  % Emit progress reports?
      'show_convergence', true,   ...
      'nltol'   ,         1.0e-6, ...  % Non-linear residual tolerance
      'lstrials',         20    , ...  % Max no of line search trials
      'maxnewt' ,         25    , ...  % Max no. of NR iterations
      'tsref'   ,         12    , ...  % Time step refinement
      'resred'  ,         0.99  , ...  % Residual reduction factor
      'wells'   ,         []    ,  ...
      'src'     ,         []    ,  ...
      'bc'      ,         []    ,  ...
      'Trans'   ,         []    ,  ...
      'dhfz'    ,         []    ,  ...
      'LinSolve',         @mldivide,...
      'gravity',          gravity(),...
      'init_state',       []       ...
       );

   opt = merge_options(opt, varargin{:});


   % Error checking -------------------------------------------------------
   assert(all(rock.poro > 0), ...
          'Zero or negative porosity found in %d cells.', ...
          sum(~(rock.poro > 0)));
   assert(~any(rock.poro > 1), ...
          'Found porosity exceeding one in %d cells.', ...
          sum(rock.poro > 1));
   if isfield(rock, 'ntg')
      assert(all(rock.ntg > 0), ...
            'Zero or negative net-to-gross found in %d cells.', ...
             sum(~(rock.ntg > 0)));
   end
   assert(~isempty(opt.Trans) || ~isfield(G, 'nnc'), ...
       ['Transmissibilities must be supplied in ''Trans'''...
       ' keyword argument when the grid has non-neighboring connections'])
   assert(all(isfinite(state.flux)), ...
          'Found %d non-finite values in state.flux. All fluxes must be finite.', ...
          sum(~isfinite(state.flux)));

   % ----------------------------------------------------------------------


   if isfield(state, 'twophaseJacobian')
       [F, Jac] = state.twophaseJacobian(G, state, rock, fluid, varargin{:});
   else
     [F, Jac] = twophaseJacobian(G, state, rock, fluid, ...
                               'wells',   opt.wells   , ...
                               'src',     opt.src     , ...
                               'bc',      opt.bc      , ...
                               'Trans',   opt.Trans,...
                               'gravity', opt.gravity, ...
                               'dhfz',    opt.dhfz);
   end

   update = @(resSol, s0, ds, dt, err)        ...
              linesearch(resSol, ds, opt.resred * err,  ...
                         @(resSol) F(resSol, s0, dt), opt.lstrials);

   dispif(opt.verbose, '\nimplicitTransport:\n');
   dispif(opt.verbose, [repmat('-', [1, 70]), '\n']);
   assert(tf>0);
   [state, report] = newtonRaphson2ph(state, tf, F, Jac, update, opt);

   dispif(opt.verbose || ~report.success, report.str);

   if ~report.success
      warning('implicitTransport:failure', ...
             'implicitTransport failed to compute time step.');
   end
   dispif(opt.verbose, [repmat('-', [1, 70]), '\n\n']);
end

%--------------------------------------------------------------------------

function [resSol, res, alph, fail] = linesearch(resSol, ds, target, F, ni)
%
% Basic idea: search for a step size 'alpha' in direction 'ds', subject to
% the restriction that alpha be in [0,1], which ensures that the objective
% function 'F' decreases.  That is: F(s + alpha*ds) < F(s).
%
% In the current implementation, alpha is reduced in a geometric sequence.
% A more sophisticated approach would ensure a certain minimum reduction as
% well.
%
   minSat = 0;     % Minimum (water) saturation
   maxSat = 1;     % Maximum (water) saturation
   capSat = @(sat) min(max(minSat, sat), maxSat);


   alph = 0;
   i    = 0;
   fail = true;
   sn = resSol;
   % Geometric line search: seems pretty robust
   while fail && (i < ni),
      sn.s(:,1) = capSat(resSol.s(:,1) + pow2(ds, alph));
      %sn.s(:,end) = 1-sum(sn.s(:,1:end-1), 2);
      res  = F(sn);

      alph = alph - 1;
      i    = i + 1;
      fail = ~(norm(res, inf) < target);
   end

   alph = pow2(alph + 1);      % Undo last (unneeded) scaling.
   resSol.s = sn.s;
end
