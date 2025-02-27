function W = control2well(u, W, varargin)
% Update val-fields of W from controls u
% If scaling is supplied, u is assumed to be scaled control s.t. 0<=u<=1
% according to scaling.boxLims
opt = struct('targets', (1:numel(W))', ...
             'scaling', []);
opt = merge_options(opt, varargin{:});
for k = 1:numel(opt.targets)
    wnr = opt.targets(k);
    if ~isempty(opt.scaling)
        bx = opt.scaling.boxLims(k,:);
        [umin, umax] = deal(bx(1), bx(2));
        W(wnr).val = u(k)*(umax-umin)+umin;
    else
        W(wnr).val = u(k);
        warning('No scaling was given, setting target well-values equal to control-values')
    end
end
end
