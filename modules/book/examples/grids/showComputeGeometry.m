%% Illustration of Geometry Computation for a Hexahedral Cell
% We go through the computation of geometry information, step by step, for
% a hexahedral cell with skewed geometry

%% Construct model
G = cartGrid([1 1 1]);
G.nodes.coords(1:end/2,:) = G.nodes.coords(1:end/2,:)*0.75;
G = computeGeometry(G);

%% Add face number, etc
clf
plotGrid(G,'FaceColor',[.7 .7 .7], 'FaceAlpha',.7);
hold on
plot3(G.faces.centroids(:,1),G.faces.centroids(:,2),G.faces.centroids(:,3),...
   'sr','MarkerSize', 24, 'LineWidth',1.5);
text(G.faces.centroids(:,1),G.faces.centroids(:,2),G.faces.centroids(:,3),...
   num2str((1:G.faces.num)'),'HorizontalAlignment','center',...
   'Color','r', 'FontWeight','demi','FontSize', 20);

plot3(G.nodes.coords(:,1),G.nodes.coords(:,2),G.nodes.coords(:,3),...
   'ob','MarkerSize', 24, 'LineWidth',1.5);
text(G.nodes.coords(:,1),G.nodes.coords(:,2),G.nodes.coords(:,3),...
   num2str((1:G.nodes.num)'),'HorizontalAlignment','center',...
   'Color','b', 'FontWeight','demi','FontSize', 20);
hold off
view(50,25), axis tight off

%% Computation of face areas, normals, and centroids
% 
faceNo  = rldecode(1:G.faces.num, diff(G.faces.nodePos), 2) .';
nodes=[(1:numel(G.faces.nodes))' faceNo G.faces.nodes]; disp(nodes)
p = G.faces.nodePos;
n = (2:size(G.faces.nodes, 1)+1) .';
n(p(2 : end) - 1) = p(1 : end-1);
localEdge2Face = sparse(1 : numel(G.faces.nodes), faceNo, 1, ...
   numel(G.faces.nodes), G.faces.num);
pC = bsxfun(@rdivide, localEdge2Face.' * G.nodes.coords(G.faces.nodes,:), ...
   diff(double(G.faces.nodePos)));
pC = localEdge2Face * pC;
pt1 = G.nodes.coords(G.faces.nodes,:);
pt2 = G.nodes.coords(G.faces.nodes(n),:);
v1 = pt2 - pt1;
v2 = pC - pt1;
sN =  cross(v1,v2)./2;
sC = (pt1 + pt2 + pC)/3;
sA = sqrt(sum(sN.^2, 2));
N  = localEdge2Face.' * sN;
A  = localEdge2Face.' * sA;
C  = bsxfun(@rdivide, localEdge2Face.'* bsxfun(@times, sA, sC), A);
sNs = sign(sum(sN.*(localEdge2Face*N),2));

%%
clf,
T = [pt1 pt2 pC]; T = T(:,[1 4 7 2 5 8 3 6 9]);
patch(T(:,1:3)',T(:,4:6)',T(:,7:9)',[.7 .7 .7],'FaceAlpha',0.9);
i = 5:8;
hold on
quiver3(pt1(i,1),pt1(i,2),pt1(i,3),v1(i,1),v1(i,2),v1(i,3),'LineWidth',2);
quiver3(pt1(i,1),pt1(i,2),pt1(i,3),v2(i,1),v2(i,2),v2(i,3),'LineWidth',2);
quiver3(pt1(i,1),pt1(i,2),pt1(i,3),sN(i,1),sN(i,2),sN(i,3),'LineWidth',2);
plot3(sC(i,1)+.01,sC(i,2),sC(i,3),'or');
hold off;
view(50,25), axis tight off, zoom(1.2), set(gca,'zdir','reverse');

%%
cla,
patch(T(:,1:3)',T(:,4:6)',T(:,7:9)',[.7 .7 .7],'FaceAlpha',0.9);
hold on
plot3(C(:,1),C(:,2),C(:,3),'.k','MarkerSize',20)
quiver3(C(2,1),C(2,2),C(2,3),N(2,1),N(2,2),N(2,3),'LineWidth',2);
hold off

%% Computing cell volumes and centroids
nF = G.cells.facePos(2)-G.cells.facePos(1);
inx = 1:nF;
faces = G.cells.faces(inx,1);
[triE, triF] = find(localEdge2Face(:,faces));
fC = C(faces,:);
cC = sum(fC)./double(nF);
relSubC = bsxfun(@minus, sC(triE,:),cC);
orient = 2*double(G.faces.neighbors(G.cells.faces(inx,1), 1) == 1) - 1;
oN = bsxfun(@times, sN(triE,:), sNs(triE).*orient(triF) );

%%
clf
X = [G.nodes.coords; pC(G.faces.nodePos(1:end-1),:); cC];
T = [G.faces.nodes, G.faces.nodes(n), faceNo+G.nodes.num, ...
   repmat(G.nodes.num+G.faces.num+1,numel(faceNo),1)];
h=tetramesh(T,X); set(h,'FaceColor',[.7 .7 .7],'facealpha',.15);
hold on;
i = [5:12 17:20];
h=tetramesh(T([3 7 10 14],:),X); set(h,'FaceColor','y','facealpha',.9);
quiver3(sC(i,1),sC(i,2),sC(i,3),oN(i,1),oN(i,2),oN(i,3),'LineWidth',2);
quiver3(sC(i,1),sC(i,2),sC(i,3),...
   relSubC(i,1),relSubC(i,2),relSubC(i,3),'LineWidth',2);
hold off;
view(75,30), axis tight off, zoom(1.3), set(gca,'zdir','reverse');

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
