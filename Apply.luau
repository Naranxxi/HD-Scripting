-- Connected Discord-GitHub
const ReplicatedStorage = game:GetService('ReplicatedStorage') -- shared storage, templates and remotes live here
const UserInputService = game:GetService('UserInputService') -- mouse position and key presses come from this one

const Packages = ReplicatedStorage:WaitForChild('Packages') -- waiting cuz the client can run before stuff replicates
const BlocksHolder = ReplicatedStorage:WaitForChild('Blocks') -- every part in here is a buildable block, no code needed
const Events = ReplicatedStorage:WaitForChild('Events') -- remotes live here, server also leaves its config here as attributes
const PlacedFolder = workspace:WaitForChild('Blocks') -- the server drops every placed block in here
const PlaceBlockEvent = Events:WaitForChild('PlaceBlock') :: RemoteEvent -- the cast tells the type checker FireServer exists
const DeleteBlockEvent = Events:WaitForChild('DeleteBlock') :: RemoteEvent -- same cast, for deleting
const TroveModule = require(Packages.Trove) -- trove by sleitnick (MIT), cleans connections and instances in one go

const Config = table.freeze({ -- frozen so nothing changes settings by accident at runtime
	GridSize = Events:GetAttribute('GridSize') or 4, -- comes from the server so both sides always agree on the grid
	MaxDistance = Events:GetAttribute('MaxDistance') or 60, -- so the ghost goes red exactly where the server would say no
	RayLength = 300, -- how far the mouse ray goes, plenty for the build area
	LerpSpeed = 25, -- higher means the ghost catches up faster
	PlaceCooldown = 0.1, -- stops holding the mouse from spamming the remote
	GhostTransparency = 0.5, -- see through enough to read as a preview
	ValidColor = Color3.fromRGB(90, 255, 130), -- green = you can place here
	InvalidColor = Color3.fromRGB(255, 90, 90), -- red = nope
	OnColor = Color3.fromRGB(28, 204, 224), -- cyan from the reference ui, build mode is on
	OffColor = Color3.fromRGB(255, 70, 86), -- red from the reference ui, build mode is off
	PreviewPadding = 1.2, -- little margin so the block doesn't touch the frame edges
	PreviewFov = 35, -- low fov flattens perspective, looks like a product shot
	OverlapPadding = Vector3.one * 0.2, -- shrinks the check box so blocks that just touch aren't overlapping
})

const Actions = { -- every input in one place, rebinding is a one line change
	PlaceBlock = Enum.UserInputType.MouseButton1, -- left click is a mouse type, not a keycode
	DeleteBlock = Enum.KeyCode.X, -- delete whatever is highlighted
	RotateBlock = Enum.KeyCode.R, -- quarter turn
	NextBlock = Enum.KeyCode.E, -- next template
	PreviousBlock = Enum.KeyCode.Q, -- previous template
	ToggleBuild = Enum.KeyCode.B, -- build mode on/off
}

const function SnapAxis(Value : number, Half : number) : number -- one axis at a time so x, y and z can share it
	return math.round((Value - Half) / Config.GridSize) * Config.GridSize + Half -- snaps the edge to the grid then goes back to the center, so blocks line up edge to edge
end

const BuildingSystemClient = {} -- the class table, methods get attached to it

export type BuildingSystemClient = { -- exported so other scripts can type their references
	Client : Player, -- who this system belongs to
	Trove : TroveModule.Trove, -- owns every connection and instance
	GhostTrove : TroveModule.Trove, -- child trove, only owns the ghost and preview
	Handlers : { [EnumItem] : () -> () }, -- input -> function dispatch table
	BlockNames : { string }, -- sorted template names
	BlockIndex : number, -- where we are in the q/e cycle
	BlockSelected : string, -- name sent to the server
	RotationSteps : number, -- 0 to 3 quarter turns
	Enabled : boolean, -- build mode flag
	CanPlace : boolean, -- last validity result, drives the ghost color
	LastPlaceTime : number, -- for the click cooldown
	TargetCFrame : CFrame?, -- nil when the mouse hits nothing
	Ghost : BasePart?, -- the see through preview in the world
	Highlight : Highlight, -- outline on the block x would delete
	ToggleButton : TextButton, -- prefab ui references below
	LeftButton : ImageButton, -- arrow button, clickable version of q
	RightButton : ImageButton, -- same but going forward, like e
	BlockLabel : TextLabel, -- shows the name of the picked block
	CounterLabel : TextLabel, -- the little 1/4 badge
	Preview : ViewportFrame, -- the 3d preview in the panel
	PreviewPart : BasePart?, -- the spinning clone inside it
	RayParams : RaycastParams, -- ray filter, skips our own character
	OverlapQuery : OverlapParams, -- overlap filter, only looks at placed blocks
}

BuildingSystemClient.__index = BuildingSystemClient -- instances fall back to the class for methods

function BuildingSystemClient:UpdateHud() : () -- refreshes the panel whenever the block or the mode changes
	self.ToggleButton.Text = if self.Enabled then 'BUILD ON' else 'BUILD OFF' -- if-expression keeps it to one line
	self.ToggleButton.BackgroundColor3 = if self.Enabled then Config.OnColor else Config.OffColor -- color tells the state at a glance
	self.BlockLabel.Text = self.BlockSelected -- shows which template is picked
	self.CounterLabel.Text = `{self.BlockIndex}/{#self.BlockNames}` -- position in the cycle, so you know how many blocks exist
end

function BuildingSystemClient:UpdatePreview(Template : BasePart) : () -- fills the 3d preview, select calls it
	const Model = Template:Clone() -- own clone so spinning it never touches the template
	Model.Anchored = true -- no physics inside the viewport
	Model.CFrame = CFrame.identity -- sits at the origin so the spin pivots on its center
	Model.Parent = self.Preview.WorldModel -- the viewport has its own little world, workspace stays clean
	self.GhostTrove:Add(Model) -- dies with the ghost when you switch blocks
	self.PreviewPart = Model -- saved so update can spin it
	const Camera = self.Preview.CurrentCamera -- the viewport renders through this, not the player camera
	const Distance = (Template.Size.Magnitude / 2) / math.sin(math.rad(Camera.FieldOfView / 2)) -- how far back a sphere around the block fits the fov
	Camera.CFrame = CFrame.lookAt(Vector3.new(1, 0.7, 1).Unit * Distance * Config.PreviewPadding, Vector3.zero) -- three quarter view from above, looking at the center
end

function BuildingSystemClient:UpdateFilter(Character : Model?) : () -- swaps the ray filter whenever the character changes
	self.RayParams.FilterDescendantsInstances = if Character then { Character } else {} -- our own body shouldn't block the mouse ray
end

function BuildingSystemClient:SelectBlock(Name : string) : () -- the one place that changes the active block
	const Template = BlocksHolder:FindFirstChild(Name) -- lookup by name, the server resolves the same string on its side
	if not (Template and Template:IsA('BasePart')) then -- guards against typos and non part children
		warn(`Block '{Name}' is not a valid template`) -- tells us which name was bad
		return -- bail out, a bad name isnt fatal
	end
	self.GhostTrove:Clean() -- old ghost and preview go first, so there's only ever one
	const Ghost = Template:Clone() -- clone so the template stays untouched
	Ghost.Anchored = true -- physics shouldn't push a preview around
	Ghost.CanCollide = false -- you can walk through it
	Ghost.CanQuery = false -- raycasts skip it, otherwise the ray hits the ghost itself
	Ghost.CanTouch = false -- no touched events from a preview
	Ghost.Transparency = Config.GhostTransparency -- see through
	Ghost.Parent = workspace -- parented last so it shows up fully set up
	self.GhostTrove:Add(Ghost) -- cleaned on the next select
	self:UpdatePreview(Template) -- keeps the panel preview in sync with the ghost
	self.Ghost = Ghost -- update reads this every frame
	self.BlockSelected = Name -- this is what we send to the server
	self:UpdateHud() -- refresh name and counter
end

function BuildingSystemClient:CycleBlock(Direction : number) : () -- direction is 1 or -1
	self.BlockIndex = (self.BlockIndex - 1 + Direction) % #self.BlockNames + 1 -- go zero based, step, wrap with modulo, back to one based
	self:SelectBlock(self.BlockNames[self.BlockIndex]) -- reuse select so ghost, preview and hud stay in sync
end

function BuildingSystemClient:Rotate() : () -- r key
	self.RotationSteps = (self.RotationSteps + 1) % 4 -- counting quarter turns avoids float drift
end

function BuildingSystemClient:ToggleBuild() : () -- b key or the button
	self.Enabled = not self.Enabled -- update reads this and hides the ghost on its own
	self:UpdateHud() -- so the button color changes
end

function BuildingSystemClient:GetMouseHit() : RaycastResult? -- shoots a ray from the cursor, nil if it hits nothing
	const Camera = workspace.CurrentCamera -- the ray starts from the player camera
	const Location = UserInputService:GetMouseLocation() -- screen position without the gui inset, which is what ViewportPointToRay wants
	const Ray = Camera:ViewportPointToRay(Location.X, Location.Y) -- turns the 2d cursor into a 3d ray
	return workspace:Raycast(Ray.Origin, Ray.Direction * Config.RayLength, self.RayParams) -- direction is a unit vector, scaling it sets the length
end

function BuildingSystemClient:ComputeCFrame(Hit : RaycastResult) : CFrame -- turns a raycast hit into a snapped and rotated spot
	const Yaw = CFrame.Angles(0, math.rad(90 * self.RotationSteps), 0) -- pure rotation, position stays zero for now
	const Rotated = Yaw:VectorToWorldSpace(self.Ghost.Size) -- size as it sits in the world, 90 degrees swaps x and z
	const Half = Rotated:Max(-Rotated) / 2 -- max(v, -v) is just abs per axis, halved gives the extents
	const Center = Hit.Position + Hit.Normal * Half -- vector times vector is per axis, so it pushes out of the hit face by half the block
	return CFrame.new(SnapAxis(Center.X, Half.X), SnapAxis(Center.Y, Half.Y), SnapAxis(Center.Z, Half.Z)) * Yaw -- snap each axis then bring the rotation back
end

function BuildingSystemClient:IsPlacementValid(Target : CFrame) : boolean -- range + overlap, same rules the server uses
	const Character = self.Client.Character -- can be nil while respawning
	const Root = Character and Character:FindFirstChild('HumanoidRootPart') :: BasePart? -- reach is measured from here
	if not Root then return false end -- no body, no building
	if (Root.Position - Target.Position).Magnitude > Config.MaxDistance then return false end -- same range check the server does
	return #workspace:GetPartBoundsInBox(Target, self.Ghost.Size - Config.OverlapPadding, self.OverlapQuery) == 0 -- rotated box query, valid only if nothing is inside
end

function BuildingSystemClient:Update(DeltaTime : number) : () -- runs every frame from the render step
	const Ghost = self.Ghost -- local copy, cheaper and it narrows the type
	if not Ghost then return end -- nothing to do before a block is picked
	if self.PreviewPart then -- the preview might not exist yet
		self.PreviewPart.CFrame = CFrame.Angles(0, os.clock(), 0) -- tied to the clock so speed doesn't depend on fps
	end
	const Hit = if self.Enabled then self:GetMouseHit() else nil -- no raycast at all while build mode is off
	self.Highlight.Adornee = if Hit and Hit.Instance:IsDescendantOf(PlacedFolder) then Hit.Instance else nil -- outlines what x would delete
	if not Hit then -- mouse over the sky or build mode off
		Ghost.Transparency = 1 -- hidden instead of destroyed, so showing it again is free
		self.TargetCFrame = nil -- also stops placing into the void
		return -- nothing to preview this frame
	end
	const Target = self:ComputeCFrame(Hit) -- snapped and rotated spot
	self.TargetCFrame = Target -- placeblock reads this
	self.CanPlace = self:IsPlacementValid(Target) -- range plus overlap
	Ghost.CFrame = Ghost.CFrame:Lerp(Target, math.min(1, DeltaTime * Config.LerpSpeed)) -- smooth follow, the min stops overshooting on lag spikes
	Ghost.Color = if self.CanPlace then Config.ValidColor else Config.InvalidColor -- green or red
	Ghost.Transparency = Config.GhostTransparency -- shows it again after being hidden
end

function BuildingSystemClient:PlaceBlock() : () -- left click lands here
	if self.BlockSelected == '' then -- nothing picked yet
		warn('No block selected') -- so it doesn't fail silently
		return -- a warn is enough, nothing to place
	end
	if not self.CanPlace or not self.TargetCFrame then return end -- red ghost means the server would refuse anyway
	const Now = os.clock() -- monotonic, safe for cooldowns
	if Now - self.LastPlaceTime < Config.PlaceCooldown then return end -- too soon since the last click
	self.LastPlaceTime = Now -- only stamped when it goes through
	PlaceBlockEvent:FireServer(self.BlockSelected, self.TargetCFrame) -- just a name and a cframe, the server builds the rest itself
end

function BuildingSystemClient:DeleteBlock() : () -- x key
	const Target = self.Highlight.Adornee -- reuses what update already found, no second ray
	if Target then -- nothing highlighted means nothing to delete
		DeleteBlockEvent:FireServer(Target) -- server checks ownership and range
	end
end

function BuildingSystemClient:Init() : () -- wires everything up once, new calls it
	self.Highlight.OutlineColor = Config.InvalidColor -- red reads as delete
	self.Highlight.FillTransparency = 1 -- outline only, a fill would hide the block color
	self.Highlight.Parent = workspace -- highlights need to live in the world to render
	self.Trove:Add(self.Highlight) -- cleaned with everything else

	const PreviewCamera = Instance.new('Camera') -- not ui, just a camera, studio drops cameras saved inside a gui so it's made here
	PreviewCamera.FieldOfView = Config.PreviewFov -- narrow fov for the product shot look
	PreviewCamera.Parent = self.Preview -- lives inside the viewport it renders for
	self.Preview.CurrentCamera = PreviewCamera -- without this the viewport shows nothing
	self.Trove:Add(PreviewCamera) -- cleaned with the system

	self.Handlers = { -- dispatch table, a new action is just one more entry
		[Actions.PlaceBlock] = function() self:PlaceBlock() end, -- closures so each one keeps self
		[Actions.DeleteBlock] = function() self:DeleteBlock() end, -- x key
		[Actions.RotateBlock] = function() self:Rotate() end, -- r key
		[Actions.NextBlock] = function() self:CycleBlock(1) end, -- +1 goes forward
		[Actions.PreviousBlock] = function() self:CycleBlock(-1) end, -- -1 goes back, modulo handles the wrap
		[Actions.ToggleBuild] = function() self:ToggleBuild() end, -- b key
	}

	self.Trove:Connect(self.LeftButton.MouseButton1Click, self.Handlers[Actions.PreviousBlock]) -- buttons reuse the key handlers so both behave the same
	self.Trove:Connect(self.RightButton.MouseButton1Click, self.Handlers[Actions.NextBlock]) -- same idea going forward
	self.Trove:Connect(self.ToggleButton.MouseButton1Click, self.Handlers[Actions.ToggleBuild]) -- and the toggle

	self.Trove:Connect(UserInputService.InputBegan, function(Input : InputObject, GameProcessed : boolean) -- one connection for every input
		if GameProcessed then return end -- the ui or chat already used it
		const Key = if Input.UserInputType == Enum.UserInputType.Keyboard then Input.KeyCode else Input.UserInputType -- keys and mouse buttons are different enums
		const Handler = self.Handlers[Key] -- direct table lookup instead of an if chain
		if Handler then -- most keys aren't mapped
			Handler() -- runs whatever that key is mapped to
		end
	end)

	self.Trove:Connect(self.Client.CharacterAdded, function(Character : Model) -- fires on every respawn
		self:UpdateFilter(Character) -- the new character has to be excluded again
	end)

	self.Trove:BindToRenderStep('BuildingGhost', Enum.RenderPriority.Camera.Value + 1, function(DeltaTime : number) -- per frame, trove unbinds it for us
		self:Update(DeltaTime) -- right after the camera moves so the ray uses this frame's camera
	end)

	self:UpdateFilter(self.Client.Character) -- character might already exist when this runs
	self:SelectBlock(self.BlockNames[1]) -- start with the first block so there's always a ghost
end

function BuildingSystemClient.new(Client : Player) : BuildingSystemClient -- constructor, builds the state then runs init
	assert(Client, 'Player is not defined') -- fail loud if someone forgets to pass the player

	const BlockNames = {} -- names only, templates get looked up when selected
	for _, Block in BlocksHolder:GetChildren() do -- generalized iteration, no pairs needed
		if Block:IsA('BasePart') then -- ignore anything that isn't a part
			table.insert(BlockNames, Block.Name) -- only the name is stored
		end
	end
	table.sort(BlockNames) -- GetChildren has no fixed order, sorting keeps q/e consistent
	assert(#BlockNames > 0, 'ReplicatedStorage.Blocks has no BasePart templates') -- no templates means nothing to build

	const Selector = Client:WaitForChild('PlayerGui', 30):WaitForChild('BuildingHud', 30):WaitForChild('BlockSelector', 30) -- the ui is prefabricated in StarterGui, this script only drives it

	const RayParams = RaycastParams.new() -- reused every frame instead of making a new one
	RayParams.FilterType = Enum.RaycastFilterType.Exclude -- list = things to skip
	const OverlapQuery = OverlapParams.new() -- same idea for the overlap check
	OverlapQuery.FilterType = Enum.RaycastFilterType.Include -- list = the only things to look at
	OverlapQuery.FilterDescendantsInstances = { PlacedFolder } -- only placed blocks can make a spot invalid
	const Trove = TroveModule.new() -- root cleanup object

	const self = setmetatable({ -- metatable gives us class style methods

		Client = Client, -- owner
		Trove = Trove, -- root trove
		GhostTrove = Trove:Extend(), -- child trove, cleaning the ghost keeps the connections alive
		Handlers = {}, -- filled in Init
		BlockNames = BlockNames, -- sorted list
		BlockIndex = 1, -- first block
		BlockSelected = '', -- set by select
		RotationSteps = 0, -- no rotation yet
		Enabled = true, -- starts in build mode
		CanPlace = false, -- update decides
		LastPlaceTime = 0, -- so the first click always passes
		Highlight = Instance.new('Highlight'), -- delete outline
		ToggleButton = Selector:WaitForChild('Toggle') :: TextButton, -- ui refs are grabbed once here, not searched every frame
		LeftButton = Selector:WaitForChild('Left') :: ImageButton, -- cast so the type checker knows the class
		RightButton = Selector:WaitForChild('Right') :: ImageButton, -- next button
		BlockLabel = Selector:WaitForChild('BlockName') :: TextLabel, -- block name text
		CounterLabel = Selector:WaitForChild('Counter') :: TextLabel, -- counter badge
		Preview = Selector:WaitForChild('Preview') :: ViewportFrame, -- 3d preview frame
		RayParams = RayParams, -- ray filter from above
		OverlapQuery = OverlapQuery, -- overlap filter from above

	}, BuildingSystemClient)

	self:Init() -- connections and first select happen here

	return self -- hands the instance back to whoever called new
end

function BuildingSystemClient:Destroy() : () -- call this to shut the system down
	self.Trove:Destroy() -- one call cleans everything this system owns (the prefab hud belongs to playergui, not us)
end

table.freeze(BuildingSystemClient) -- nobody patches the class at runtime

return BuildingSystemClient -- so the localscript can require it
