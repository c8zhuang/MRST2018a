classdef ThreePhaseBlackOilDPModel < DualPorosityReservoirModel
    % Three phase with optional dissolved gas and vaporized oil
    properties
        % Flag deciding if gas can be dissolved into the oil phase
        disgas
        % Flag deciding if oil can be vaporized into the gas phase
        vapoil

        % Maximum relative Rs/Rv increment
        drsMaxRel
        % Maximum absolute Rs/Rv increment
        drsMaxAbs
    end

    methods
        function model = ThreePhaseBlackOilDPModel(G, rock, fluid, rock_matrix, fluid_matrix, dp_info, varargin)
            model = model@DualPorosityReservoirModel(G, rock, fluid, rock_matrix, fluid_matrix, dp_info, varargin{:});

            % Typical black oil is disgas / dead oil, but all combinations
            % are supported
            model.vapoil = false;
            model.disgas = false;

            % Max increments
            model.drsMaxAbs = inf;
            model.drsMaxRel = inf;

            % Blackoil -> use CNV style convergence 
            model.useCNVConvergence = true;

            % All phases are present
            model.oil = true;
            model.gas = true;
            model.water = true;
            model.matrixVarNames = {'pwm','pom','pgm','swm','som','sgm'};

            model = merge_options(model, varargin{:});

            d = model.inputdata;
            if ~isempty(d)
                % Assume ECL-style input deck, as this is the only
                % supported format at the moment.
                if isfield(d, 'RUNSPEC')
                    if isfield(d.RUNSPEC, 'VAPOIL')
                        model.vapoil = d.RUNSPEC.VAPOIL;
                    end
                    if isfield(d.RUNSPEC, 'DISGAS')
                        model.disgas = d.RUNSPEC.DISGAS;
                    end
                else
                    error('Unknown dataset format!')
                end
            end
        end

        % --------------------------------------------------------------------%
        function [fn, index] = getVariableField(model, name)
            switch(lower(name))
                case {'rs', 'rv', 'rsm', 'rvm'}
                    % RS and RV for gas dissolving into the oil phase and oil
                    % components vaporizing into the gas phase respectively.
                    fn = lower(name);
                    index = 1;
                otherwise
                    % Basic phases are known to the base class
                    [fn, index] = getVariableField@DualPorosityReservoirModel(model, name);
            end
        end

        % --------------------------------------------------------------------%
        function [problem, state] = getEquations(model, state0, state, dt, drivingForces, varargin)
            [problem, state] = equationsBlackOilDP(state0, state, model, dt, ...
                            drivingForces, varargin{:});

        end

        % --------------------------------------------------------------------%
        function state = validateState(model, state)
            % Check parent class
            state = validateState@DualPorosityReservoirModel(model, state);
            nc = model.G.cells.num;
            if model.disgas
                % RS must be supplied for all cells. This may cause an error.
                model.checkProperty(state, 'rs', nc, 1);

                % RS must be supplied for all cells. This may cause an error.
                model.checkProperty(state, 'rsm', nc, 1);
            else
                % RS does not really matter. Assign single value.
                fn = model.getVariableField('rs');
                if ~isfield(state, fn)
                    dispif(model.verbose, ...
                        ['Missing field "', fn, '" added since disgas is not enabled.\n']);
                    state.(fn) = 0;
                end
                clear fn

                % Doing the same for the matrix
                fn = model.getVariableField('rsm');
                if ~isfield(state, fn)
                    dispif(model.verbose, ...
                        ['Missing field "', fn, '" added since disgas is not enabled.\n']);
                    state.(fn) = 0;
                end
                clear fn
            end
            if model.vapoil
                % RV must be supplied for all cells. This may cause an error.
                model.checkProperty(state, 'rv', nc, 1);

                % RV must be supplied for all cells. This may cause an error.
                model.checkProperty(state, 'rvm', nc, 1);
            else
                % RS does not really matter. Assign single value.
                fn = model.getVariableField('rv');
                if ~isfield(state, fn)
                    dispif(model.verbose, ...
                        ['Missing field "', fn, '" added since vapoil is not enabled.\n']);
                    state.(fn) = 0;
                end
                clear fn

                % Doing the same for the matrix
                fn = model.getVariableField('rvm');
                if ~isfield(state, fn)
                    dispif(model.verbose, ...
                        ['Missing field "', fn, '" added since disgas is not enabled.\n']);
                    state.(fn) = 0;
                end
                clear fn
            end
        end

        % --------------------------------------------------------------------%
        function [state, report] = updateState(model, state, problem, dx, drivingForces)
            saturations = lower(model.getSaturationVarNames);
            wi = strcmpi(saturations, 'sw');
            oi = strcmpi(saturations, 'so');
            gi = strcmpi(saturations, 'sg');

            vars = problem.primaryVariables;
            removed = false(size(vars));
            if model.disgas || model.vapoil
                % The VO model is a bit complicated, handle this part
                % explicitly.
                state0 = state;

                state = model.updateStateFromIncrement(state, dx, problem, 'pressure', model.dpMaxRel, model.dpMaxAbs);
                state = model.capProperty(state, 'pressure', model.minimumPressure, model.maximumPressure);

                [vars, ix] = model.stripVars(vars, 'pressure');
                removed(~removed) = removed(~removed) | ix;

                % Black oil with dissolution
                so = model.getProp(state, 'so');
                sw = model.getProp(state, 'sw');
                sg = model.getProp(state, 'sg');

                % Magic status flag, see inside for doc
                st = model.getCellStatusVO(state0, so, sw, sg);

                dr = model.getIncrement(dx, problem, 'x');
                dsw = model.getIncrement(dx, problem, 'sw');
                % Interpretation of "gas" phase varies from cell to cell, remove
                % everything that isn't sG updates
                dsg = st{3}.*dr - st{2}.*dsw;

                if model.disgas
                    state = model.updateStateFromIncrement(state, st{1}.*dr, problem, ...
                                                           'rs', model.drsMaxRel, model.drsMaxAbs);
                end

                if model.vapoil
                    state = model.updateStateFromIncrement(state, st{2}.*dr, problem, ...
                                                           'rv', model.drsMaxRel, model.drsMaxAbs);
                end

                dso = -(dsg + dsw);

                ds = zeros(numel(so), numel(saturations));
                ds(:, wi) = dsw;
                ds(:, oi) = dso;
                ds(:, gi) = dsg;

                state = model.updateStateFromIncrement(state, ds, problem, 's', model.dsMaxRel, model.dsMaxAbs);
                % We should *NOT* be solving for oil saturation for this to make sense
                assert(~any(strcmpi(vars, 'so')));
                state = computeFlashBlackOil(state, state0, model, st);
                state.s  = bsxfun(@rdivide, state.s, sum(state.s, 2));

                %  We have explicitly dealt with rs/rv properties, remove from list
                %  meant for autoupdate.
                [vars, ix] = model.stripVars(vars, {'sw', 'so', 'sg', 'rs', 'rv', 'x'});
                removed(~removed) = removed(~removed) | ix;

            end

            % We may have solved for a bunch of variables already if we had
            % disgas / vapoil enabled, so we remove these from the
            % increment and the linearized problem before passing them onto
            % the generic reservoir update function.
            problem.primaryVariables = vars;
            dx(removed) = [];

            % Parent class handles almost everything for us
            [state, report] = updateState@DualPorosityReservoirModel(model, state, problem, dx, drivingForces);
        end

        % --------------------------------------------------------------------%
        function scaling = getScalingFactorsCPR(model, problem, names)
            % Get approximate, impes-like pressure scaling factors
            nNames = numel(names);

            scaling = cell(nNames, 1);
            handled = false(nNames, 1);

            % Take averaged pressure for scaling factors
            state = problem.state;
            fluid = model.fluid;
            p = mean(state.pressure);

            for iter = 1:nNames
                name = lower(names{iter});
                switch name
                    case 'oil'
                        if model.disgas
                           rs = fluid.rsSat(p);
                           bO = fluid.bO(p, rs, true);
                        else
                           bO = fluid.bO(p);
                        end
                        s = 1./bO;
                    case 'water'
                        bW = fluid.bW(p);
                        s = 1./bW;
                    case 'gas'
                        if model.vapoil
                            rv = fluid.rvSat(p);
                            bG = fluid.bG(p, rv, true);
                        elseif model.gas
                            bG = fluid.bG(p);
                        end
                        s = 1./bG;
                    otherwise
                        continue
                end
                sub = strcmpi(problem.equationNames, name);

                scaling{iter} = s;
                handled(sub) = true;
            end
            if ~all(handled)
                % Get rest of scaling factors from parent class
                other = getScalingFactorsCPR@DualPorosityReservoirModel(model, problem, names(~handled));
                [scaling{~handled}] = other{:};
            end
        end

        function st = getCellStatusVO(model, state, sO, sW, sG)
            status = [];
            if isfield(state, 'status')
                status = state.status;
            end
            st = getCellStatusVO(sO, sW, sG, 'status', status, 'vapoil', ...
                                     model.vapoil, 'disgas', model.disgas);
        end

        function [sG, rs, rv, rsSat, rvSat] = calculateHydrocarbonsFromStatusBO(model, ...
                                                              status, sO, x, rs, ...
                                                              rv, pressure)
            [sG, rs, rv, rsSat, rvSat] = calculateHydrocarbonsFromStatusBO(model.fluid, ...
                                                              status, sO, x, rs, ...
                                                              rv, pressure, model.disgas, model.vapoil);
        end
        function dismat = getDissolutionMatrix(model, rs, rv)
            actPh = model.getActivePhases();
            nPh = nnz(actPh);
            if ~model.disgas
                rs = [];
            end
            if ~model.vapoil
                rv = [];
            end

            dismat = cell(1, nPh);
            [dismat{:}] = deal(cell(1, nPh));
            ix = 1;
            jx = 1;
            for i = 1:3
                if ~actPh(i)
                    continue
                end
                for j = 1:3
                    if ~actPh(j)
                        continue
                    end
                    if i == 2 && j == 3
                        dismat{i}{j} = rv;
                    elseif i == 3 && j == 2
                        dismat{i}{j} = rs;
                    end
                    jx = jx + 1;
                end
                ix = ix + 1;
            end
        end

        function components = getDissolutionMatrixMax(model, pressure)
            [rsMax, rvMax] = deal([]);
            if model.disgas
                rsMax = model.fluid.rsSat(pressure);
            end
            if model.vapoil
                rvMax = model.fluid.rvSat(pressure);
            end
            components = model.getDissolutionMatrix(rsMax, rvMax);
        end

    end
end

%{
Copyright 2009-2016 SINTEF ICT, Applied Mathematics.

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
