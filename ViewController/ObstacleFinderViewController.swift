import UIKit
import ARKit
import RealityKit
import SceneKit
import VideoToolbox
import Vision

class ObstacleFinderViewController: UIViewController, ARSCNViewDelegate, UIGestureRecognizerDelegate
{
    @IBOutlet weak var arscnView : ARSCNView!
    
    private var floors : [UUID:SCNNode]!
    
    private var walls : [UUID:SCNNode]!
    
    private var boundingBoxes : [ObstacleBoundingBoxView]!
    
    private var planeQueue : DispatchQueue!
    
    private var obstacleQueue : DispatchQueue!
    
    private var lockQueue : DispatchQueue!
    
    private var classificationQueue : DispatchQueue!
    
    private var fileName : String!
    
    private var viewport : CGRect!
    
    private var obstaclePerAnchor : [UUID: [Obstacle]]!
    
    private var processingPerAnchor : [UUID: Bool]!
    
    private var knownObstacles : [Obstacle]!
    
    private var colorPerAnchor : [UUID : UIColor]!
    
    private var chestHeight : Float!
    
    private var refNode : SCNNode!
    
    private var classification : Bool!
    
    @IBOutlet private var clusterLbl : UILabel!
    
    @IBOutlet private var anchorLbl : UILabel!
    
    @IBOutlet private var obstacleLbl : UILabel!
    
    private var imagePredictor : ImagePredictor!
    
    @IBOutlet private var previewView : UIImageView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        guard #available(iOS 14.0, *) else { return }
        
        setupViewVariables()
        
        setupARSCNView()
        
        setupBoundingBoxes()
    }
    
    func setupViewVariables()
    {
        UIApplication.shared.isIdleTimerDisabled = true
        colorPerAnchor=[:]
        processingPerAnchor=[:]
        floors=[:]
        walls=[:]
        classification = false
        planeQueue = DispatchQueue(label: "com.odview.planequeue.serial", qos: .userInteractive)
        obstacleQueue = DispatchQueue(label: "com.odview.obstaclequeue.serial", qos: .userInteractive)
        lockQueue = DispatchQueue(label: "com.odview.lockqueue.serial", qos: .userInteractive)
        classificationQueue = DispatchQueue(label: "com.odview.classification.serial", qos: .userInteractive)
        obstaclePerAnchor = [:]
        knownObstacles = []
        viewport = CGRect(x: 0.0, y: 0.0, width: 390.0, height: 753.0)
        if(chestHeight==nil) { chestHeight = 1.5 }
    }
    
    func setupARSCNView()
    {
        imagePredictor = ImagePredictor()
        arscnView.delegate=self
        arscnView.isOpaque=true
        arscnView.frame=self.view.frame
        arscnView.showsStatistics=true
        arscnView.preferredFramesPerSecond = Constants.PREFERRED_FPS
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.sceneReconstruction = .meshWithClassification
        arscnView.session.run(configuration)
        refNode = SCNNode()
        arscnView.scene.rootNode.addChildNode(refNode)
    }
    
    func setupBoundingBoxes()
    {
        boundingBoxes = []
        for _ in 0..<Constants.MAX_OBSTACLE_NUMBER
        {
            let boundingBox = ObstacleBoundingBoxView()
            boundingBox.addToLayer(arscnView.layer)
            boundingBoxes.append(boundingBox)
        }
    }
    
    func setChestHeight(height: Decimal)
    {
        chestHeight = Float("\(height)")
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?)
    {
    }
    
    override func viewWillAppear(_ animated: Bool)
    {
        super.viewWillAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool)
    {
        super.viewWillDisappear(animated)
        guard #available(iOS 14.0, *) else { return }
        arscnView.session.pause()
    }
    
    func createGeometry(vertices:[SCNVector3], indices:[Int32], primitiveType:SCNGeometryPrimitiveType) -> SCNGeometry
    {
        // Computed property that indicates the number of primitives to create based on primitive type
        var primitiveCount:Int
        {
            get {
                switch primitiveType
                {
                case SCNGeometryPrimitiveType.line:
                    return indices.count / 2
                case SCNGeometryPrimitiveType.point:
                    return indices.count
                default:
                    return indices.count / 3
                }
            }
        }
        
        // Create the source and elements in the appropriate format
        let data = NSData(bytes: vertices, length: MemoryLayout<SCNVector3>.size * vertices.count)
        let vertexSource = SCNGeometrySource(
            data: data as Data, semantic: SCNGeometrySource.Semantic.vertex,
            vectorCount: vertices.count, usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<SCNVector3>.size)
        
        let indexData = NSData(bytes: indices, length: MemoryLayout<Int32>.size * indices.count)
        let element = SCNGeometryElement(
            data: indexData as Data, primitiveType: primitiveType,
            primitiveCount: primitiveCount, bytesPerIndex: MemoryLayout<Int32>.size)
        
        return SCNGeometry(sources: [vertexSource], elements: [element])
    }
    
    func createLine(vertices:[SCNVector3], indices:[Int32], node: SCNNode) -> SCNNode
    {
        let indices = [Int32(0), Int32(1)]
        let geometry = createGeometry(vertices: vertices, indices: indices, primitiveType: SCNGeometryPrimitiveType.line)
        geometry.firstMaterial?.diffuse.contents=CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let line = SCNNode(geometry: geometry)
        return line
    }
    
    func considerTriangle(_ classification : ARMeshClassification) -> Bool
    {
        return classification == .none || classification == .seat || classification == .table
    }
    
    func calculateTriangleNormal(_ vertices : [SCNVector3]) -> SCNVector3
    {
        if(vertices.count<2) { return SCNVector3Zero }
        let firstVector = vertices[1].getSimd()-vertices[0].getSimd()
        let secondVector = vertices[2].getSimd()-vertices[0].getSimd()
        let normal = SCNVector3(cross(secondVector, firstVector)).normalize()
        return normal
    }
    
    func addFloorWallPlane(planeAnchor : ARPlaneAnchor, node : SCNNode)
    {
        planeQueue.async
        { [weak self] in
            let width = CGFloat(planeAnchor.extent.x)
            let height = CGFloat(planeAnchor.extent.z)
            //Se l'area trovata è minore di 1mq, allora ignoro il piano
            if(width*height<Constants.AREA_THRESHOLD) { return }
            
            let plane: SCNPlane = SCNPlane(width: width, height: height)
            let planeNode = SCNNode(geometry: plane)
            planeNode.simdPosition = planeAnchor.center
            planeNode.eulerAngles.x = -.pi / 2
            //Il piano trovato è orizzontale o verticale?
            if(planeAnchor.alignment == .horizontal)
            {
                guard let frame = self!.arscnView.session.currentFrame else { return }
                let cameraWorldPosition = SCNVector3(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                let floorLevel = cameraWorldPosition.y-self!.chestHeight
                let planeWorldPosition = SCNVector3(node.simdConvertPosition(planeNode.position.getSimd(), to: nil))
                /*
                 Se il piano orizzontale che voglia aggiungere è sopra l'ipotetico
                 livello del suolo, allora lo ignoro
                */
                if(abs(planeWorldPosition.y-floorLevel)>Constants.PLANE_DISTANCE_THRESHOLD)
                {
                    return
                }
                planeNode.geometry?.firstMaterial?.diffuse.contents=UIColor(cgColor: CGColor(red: 0, green: 1, blue: 1, alpha: 0.8))
                self!.floors[planeAnchor.identifier]=planeNode
            }
            else
            {
                planeNode.geometry?.firstMaterial?.diffuse.contents=UIColor(cgColor: CGColor(red: 0, green: 1, blue: 0, alpha: 0.8))
                self!.walls[planeAnchor.identifier]=planeNode
            }
            
            for i in stride(from: node.childNodes.count-1, through: 0, by: -1)
            {
                node.childNodes[i].removeFromParentNode()
            }
            node.addChildNode(planeNode)
        }
    }
    
    func adaptFrame(frame : ARFrame) -> CGImage?
    {
        let imageBuffer = frame.capturedImage
        let imageSize = CGSize(width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer))
        let viewPortSize = viewport.size
        let interfaceOrientation : UIInterfaceOrientation = .portrait
        let frameImage = CIImage(cvImageBuffer: imageBuffer)
        // Normalizzo coordinate
        let normalizeTransform = CGAffineTransform(scaleX: 1.0/imageSize.width, y: 1.0/imageSize.height)
        // Ruoto il frame
        let flipTransform = (interfaceOrientation.isPortrait) ? CGAffineTransform(scaleX: -1, y: -1).translatedBy(x: -1, y: -1) : .identity
        // Passo a screen coordinate
        let displayTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewPortSize)
        // Scalo
        let toViewPortTransform = CGAffineTransform(scaleX: viewPortSize.width, y: viewPortSize.height)
        // Crop di quello che non c'è a schermo
        let transformedImage = frameImage.transformed(by: normalizeTransform.concatenating(flipTransform).concatenating(displayTransform).concatenating(toViewPortTransform)).cropped(to: viewport)
        // Renderizzo il frame croppato
        let context = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
        let frameCgImage = context.createCGImage(transformedImage, from: transformedImage.extent)
        context.clearCaches()
        return frameCgImage
    }

    func findObstacles(node: SCNNode, anchor: ARAnchor, renderer: SCNSceneRenderer)
    {
        guard let frame = arscnView.session.currentFrame else
        {
            lockQueue.async
            { [weak self] in
                self!.processingPerAnchor[anchor.identifier]=false
            }
            return
        }
        
        let meshAnchor = anchor as! ARMeshAnchor
        
        let cameraWorldPosition = SCNVector3(
            x: frame.camera.transform.columns.3.x,
            y: frame.camera.transform.columns.3.y,
            z: frame.camera.transform.columns.3.z)
        
        let currentAnchorWorldPosition = SCNVector3(meshAnchor.transform.position)
        
        //L'ancora che voglio aggiungere è troppo distante
        if(SCNVector3.distanceBetween(cameraWorldPosition, currentAnchorWorldPosition)>=Constants.MAX_ANCHOR_DISTANCE)
        {
            lockQueue.async
            { [weak self] in
                self!.processingPerAnchor[anchor.identifier]=false
            }
            return
        }
        
        var walls : [(SCNVector3, SCNVector3)] = []
        var floors : [(SCNVector3, SCNVector3)] = []
        
        guard let pointOfView = renderer.pointOfView else { return }
        
        //Recupero normale e posizione di tutti i muri e pavimenti
        planeQueue.sync
        { [weak self] in
            for uuid in self!.walls.keys
            {
                if(self!.walls[uuid] != nil)
                {
                    let wall = self!.walls[uuid]!
                    //Rimuovo i muri non più visibili
                    if(!renderer.isNode(wall, insideFrustumOf: pointOfView))
                    {
                        wall.removeFromParentNode()
                        self!.walls[uuid]=nil
                        continue
                    }
                    var normal = SCNVector3(wall.simdConvertVector(simd_float3(x: 0, y: 0, z: 1), to: nil))
                    normal = normal.normalize()
                    let wallWorldPosition = wall.worldPosition
                    walls.append((wallWorldPosition, normal))
                }
            }
            
            for uuid in self!.floors.keys
            {
                if(self!.floors[uuid] != nil)
                {
                    let floor = self!.floors[uuid]!
                    //Rimuovo i piani pavimento non più visibili
                    if(!renderer.isNode(floor, insideFrustumOf: pointOfView))
                    {
                        floor.removeFromParentNode()
                        self!.floors[uuid]=nil
                        continue
                    }
                    var normal = SCNVector3(floor.simdConvertVector(simd_float3(x: 0, y: 0, z: 1), to: nil))
                    normal = normal.normalize()
                    let floorWorldPosition = floor.worldPosition
                    floors.append((floorWorldPosition, normal))
                }
            }
        }
        
        //Eseguo l'obstacle detection a livello di ancora
        obstacleQueue.async
        { [weak self] in
            let start = DispatchTime.now()
            //Variabili per la stima del floor level
            let meshGeometry = meshAnchor.geometry
            //Se non ho piani che corrispondono al suolo
            if(floors.count==0)
            {
                self!.lockQueue.async
                { [weak self] in
                    self!.processingPerAnchor[anchor.identifier]=false
                }
                return
            }
            
            var faceIndices : [Int] = []
            var vertices : [SCNVector3] = []
            var indices : [Int32] = []
            let floorLevel = cameraWorldPosition.y-self!.chestHeight
            
            var indicesAdded : [UInt32: Int32] = [:]
            print("pre filtering:\(meshAnchor.geometry.vertices.count)")
            
            var limiter = 0
            
            //MARK: Filtro facce
            for i in 0..<meshGeometry.faces.count
            {
                let triangleLocalPosition = meshGeometry.centerOf(faceWithIndex: i)
                let triangleWorldPosition = node.convertPosition(triangleLocalPosition, to: nil)
                let triangleScreenPoint = frame.camera.projectPoint(triangleWorldPosition.getSimd(), orientation: .portrait, viewportSize: self!.viewport.size)
                
                //Rimuovo le facce fuori dallo schermo
                if(triangleScreenPoint.x<0 || self!.viewport.width<triangleScreenPoint.x || triangleScreenPoint.y<0 || triangleScreenPoint.y>self!.viewport.height)
                {
                    continue
                }
                
                //Rimuovo le facce la cui classificazione non ci interessa (muri, pavimento)
                let classification=meshAnchor.geometry.classificationOf(faceWithIndex: i)
                
                if(!self!.considerTriangle(classification))
                {
                    continue
                }
                
                var shouldContinue = false
                
                //Rimuovo triangoli vicini ai muri
                for wall in walls
                {
                    let normal = wall.1.getSimd()
                    let relativePosition = triangleWorldPosition.getSimd()-wall.0.getSimd()
                    let distance = simd_dot(normal, relativePosition)
                    if(abs(distance)<Constants.PLANE_DISTANCE_THRESHOLD)
                    {
                        shouldContinue=true
                        break
                    }
                }
                
                if(shouldContinue) { continue }
                
                //Rimuovo triangoli del pavimento e sotto il pavimento
                for floor in floors
                {
                    let normal = floor.1.getSimd()
                    let relativePosition = triangleWorldPosition.getSimd()-floor.0.getSimd()
                    let distance = simd_dot(normal, relativePosition)
                    if(abs(distance)<Constants.PLANE_DISTANCE_THRESHOLD || distance<0)
                    {
                        shouldContinue=true
                        break
                    }
                }
                
                if(shouldContinue) { continue }
                
                /*
                 Rimuovo le facce che sono sotto l'ipotetica Y del suolo
                 La Y del suolo è calcolata partendo dalla Y del device meno
                 la distanze del busto al suolo.
                 */
                if(abs(triangleWorldPosition.y-floorLevel)<=Constants.PLANE_DISTANCE_THRESHOLD)
                {
                    continue
                }
                
                let verticesLocalPosition = meshGeometry.verticesOf(faceWithIndex: i).map
                {
                    SCNVector3(x: $0.0, y: $0.1, z: $0.2)
                }
                
                let vertexIndices = meshGeometry.vertexIndicesOf(faceWithIndex: i)
                faceIndices.append(i)
                //Per evitare di aggiungere punti che non mi servono
                for i in 0..<3
                {
                    if(indicesAdded[vertexIndices[i]] != nil)
                    {
                        indices.append(indicesAdded[vertexIndices[i]]!)
                    }
                    else
                    {
                        vertices.append(verticesLocalPosition[i])
                        indices.append(Int32(vertices.count-1))
                        indicesAdded[vertexIndices[i]]=Int32(vertices.count-1)
                    }
                }
                if(limiter>Constants.MAX_NUMBER_OF_TRIANGLE)
                {
                    break
                }
                limiter=limiter+1
            }
            
            //Visualizzo le facce degli ostacoli
            node.geometry = self!.createGeometry(vertices: vertices, indices: indices, primitiveType: .triangles)
            node.geometry?.firstMaterial?.diffuse.contents=UIColor(cgColor: CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
            
            var faceClusters : [Set<UInt32>] = []
            var pointClusters : [Set<UInt32>] = []
            
            print("post filtering:\(vertices.count)")
            
            //MARK: Clustering
            for faceIndex in faceIndices
            {
                let vertexIndices = meshAnchor.geometry.vertexIndicesOf(faceWithIndex: faceIndex)
                
                var pointClustersConnected : [Set<UInt32>] = []
                var faceClustersConnected : [Set<UInt32>] = []
                
                for i in stride(from: pointClusters.count-1, through: 0, by: -1)
                {
                    if(pointClusters[i].contains(vertexIndices[0]) || pointClusters[i].contains(vertexIndices[1]) || pointClusters[i].contains(vertexIndices[2]))
                    {
                        //Allora il vertice è connesso a uno dei cluster esistenti
                        pointClustersConnected.append(pointClusters[i])
                        faceClustersConnected.append(faceClusters[i])
                        pointClusters.remove(at: i)
                        faceClusters.remove(at: i)
                    }
                }
                
                var newPointCluster : Set<UInt32> = []
                var newFaceCluster : Set<UInt32> = []
                
                if(pointClustersConnected.count != 0)
                {
                    //Altrimenti bisogna fare il merge di tutti i cluster connessi
                    for i in 0..<pointClustersConnected.count
                    {
                        newPointCluster=newPointCluster.union(pointClustersConnected[i])
                        newFaceCluster=newFaceCluster.union(faceClustersConnected[i])
                    }
                }
                newPointCluster.insert(vertexIndices[0])
                newPointCluster.insert(vertexIndices[1])
                newPointCluster.insert(vertexIndices[2])
                newFaceCluster.insert(UInt32(faceIndex))
                pointClusters.append(newPointCluster)
                faceClusters.append(newFaceCluster)
            }
            
            var obstacles : [Obstacle] = []
            
            //MARK: Generazione mbr
            for i in stride(from: faceClusters.count-1, through: 0, by: -1)
            {
                if(faceClusters[i].count<Constants.MIN_NUMBER_TRIANGLES_FOR_CLUSTER)
                {
                    faceClusters.remove(at: i)
                    pointClusters.remove(at: i)
                    continue
                }
                
                let faceCluster = faceClusters[i]
                let obstacle = Obstacle()
                for faceIndex in faceCluster
                {
                    let vertices = meshGeometry.verticesOf(faceWithIndex: Int(faceIndex)).map
                    {
                        SCNVector3(x: $0.0, y: $0.1, z: $0.2)
                    }
                    
                    let worldVertices = vertices.compactMap
                    {
                        node.convertPosition($0, to: nil)
                    }
                    
                    for j in 0..<3
                    {
                        obstacle.updateBoundaries(frame: frame, viewportSize: self!.viewport.size, worldPoint: worldVertices[j])
                    }
                }
                obstacles.append(obstacle)
            }
            
            //MARK: Merge MBR generate a partire da questa ancora
            self!.merge(obstacles: &obstacles)
            
            self!.lockQueue.async
            { [weak self] in
                self!.obstaclePerAnchor[anchor.identifier]=obstacles
                self!.processingPerAnchor[anchor.identifier]=false
            }
            
            let end = DispatchTime.now()
            let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds // <<<<< Difference in nano seconds (UInt64)
                let timeInterval = Double(nanoTime) / 1_000_000_000 // Technically could overflow for long running tests
            print("\(meshAnchor.geometry.faces.count) : \(timeInterval) seconds")
            
        }
    }
    
    func merge(obstacles : inout [Obstacle])
    {
        var i = 0
        while(i<obstacles.count)
        {
            var obstacle = obstacles[i]
            var j = obstacles.count-1
            while(j>i)
            {
                var otherObstacle = obstacles[j]
                if(obstacle.getDistanceWithOtherObstacle(other: otherObstacle)<=Constants.MERGE_DISTANCE)
                {
                    //Se la distanza tra le due mbr è minore della
                    //merge distance, allora eseguo il merge tra i
                    //2 oggetti.
                    obstacle.mergeWithOther(other: otherObstacle)
                    obstacles[i] = obstacle
                    //Rimuovo ostacolo non necessario.
                    obstacles.remove(at: j)
                    //Riprendo lo scan per i merge dall'inizio.
                    i=0
                    j=obstacles.count-1
                    obstacle = obstacles[i]
                    otherObstacle = obstacles[j]
                }
                else
                {
                    //Altrimenti passo all'ostacolo successivo
                    j-=1
                }
            }
            i=i+1
        }
    }
    
    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor)
    {
        if((anchor as? ARPlaneAnchor) != nil)
        {
            let planeAnchor = anchor as! ARPlaneAnchor
            addFloorWallPlane(planeAnchor: planeAnchor, node: node)
        }
        else if((anchor as? ARMeshAnchor) != nil)
        {
            lockQueue.sync
            { [weak self] in
                if(self!.processingPerAnchor[anchor.identifier]==nil)
                {
                    self!.processingPerAnchor[anchor.identifier]=false
                }
                let processing = self!.processingPerAnchor[anchor.identifier]!
                guard !processing else { return }
                self!.processingPerAnchor[anchor.identifier]=true
            }
            findObstacles(node: node, anchor: anchor, renderer: renderer)
        }
    }
    
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode?
    {
        let node = SCNNode()
        node.transform=SCNMatrix4(anchor.transform)
        return node
    }
    
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval)
    {
        //Se non ci sono classificazioni in corso, allora procedo
        //Con la classificazione delle mbr
        guard !classification else { return }
        classification = true
        guard let frame = arscnView.session.currentFrame else
        {
            classification = false
            return
        }
        var counter = 0
        var anchorCounter = 0
        var newObstacles : [Obstacle] = []
        
        //MARK: Recupero i cluster associati alle ancore
        lockQueue.sync
        { [weak self] in
            let arMeshAnchors = frame.anchors.compactMap
            {
                $0 as? ARMeshAnchor
            }
            //Rimuovo i nodi non visibili
            let pointOfView = renderer.pointOfView!
            for arMeshAnchor in arMeshAnchors
            {
                let obstacleNode = self!.arscnView.node(for: arMeshAnchor)
                if((obstacleNode != nil &&
                    !renderer.isNode(obstacleNode!, insideFrustumOf: pointOfView)) || obstacleNode==nil)
                {
                    self!.obstaclePerAnchor[arMeshAnchor.identifier]=nil
                }
                else
                {
                    continue
                }
            }
            
            for key in self!.obstaclePerAnchor.keys
            {
                guard let obstacles = self!.obstaclePerAnchor[key] else { continue }
                for obstacle in obstacles
                {
                    newObstacles.append(Obstacle(obstacle))
                }
                counter += obstacles.count
            }
            anchorCounter=self!.obstaclePerAnchor.keys.count
        }
        
        classificationQueue.async
        { [weak self] in
            let start = DispatchTime.now()
            
            //MARK: Unione dei cluster
            self!.merge(obstacles: &newObstacles)
            
            //MARK: Classificazione degli ostacoli
            DispatchQueue.global(qos: .userInteractive).async
            { [weak self] in
                let frameCgImage = self!.adaptFrame(frame: frame)
                //Passo al classificatore il frame con le bounding box
                self!.imagePredictor.classifyNewObstacles(cgImage: frameCgImage, for: &newObstacles)
                
                if(self!.knownObstacles.count>0)
                {
                    var marked : [Bool] = Array(repeating: false, count: self!.knownObstacles.count)
                    
                    for i in stride(from: 0, through: self!.knownObstacles.count-1, by: 1)
                    {
                        for j in stride(from: newObstacles.count-1, through: 0, by: -1)
                        {
                            let newObstacle = newObstacles[j]
                            
                            if(self!.knownObstacles[i].areIntersected(other: newObstacle))
                            {
                                if(!marked[i])
                                {
                                    self!.knownObstacles[i].resetBoundingBox()
                                    marked[i]=true
                                }
                                let newPrediction = newObstacle.getMostProbablePrediction()
                                self!.knownObstacles[i].mergeWithOther(other: newObstacle)
                                self!.knownObstacles[i].addNewPrediction(newPrediction: newPrediction)
                                newObstacles.remove(at: j)
                            }
                        }
                    }
                    
                    //Se un ostacolo tra quelli conosciuti, non viene riconfermato
                    //allora lo si elimina.
                    for i in stride(from: marked.count-1, through: 0, by: -1)
                    {
                        if(!marked[i])
                        {
                            self!.knownObstacles.remove(at: i)
                        }
                    }
                }
                
                //Se un nuovo ostacolo non viene fuso con quelli già conosciuti
                //allora è un nuovo ostacolo e va aggiunto.
                for newObstacle in newObstacles
                {
                    self!.knownObstacles.append(newObstacle)
                }
                
                DispatchQueue.main.async
                { [weak self] in
                    self!.clusterLbl.text = String(format:"Clusters: %d", counter)
                    self!.anchorLbl.text = String(format:"Anchors: %d", anchorCounter)
                    self!.obstacleLbl.text = String(format: "Obstacles: %d", self!.knownObstacles.count)
                    var i = 0
                    for obstacle in self!.knownObstacles
                    {
                        let prediction = self!.knownObstacles[i].getMostProbablePrediction()
                        let label = prediction.getDescriptionString()
                        let obstacleRect = obstacle.getObstacleRect()
                        self!.boundingBoxes[i].show(rect: obstacleRect, label: label, color: UIColor.blue)
                        i+=1
                    }
                    
                    i=self!.knownObstacles.count-newObstacles.count
                    while(i<self!.knownObstacles.count)
                    {
                        let prediction = self!.knownObstacles[i].getMostProbablePrediction()
                        let label = prediction.getDescriptionString()
                        let obstacleRect = self!.knownObstacles[i].getObstacleRect()
                        self!.boundingBoxes[i].show(rect: obstacleRect, label: label, color: UIColor.red)
                        i+=1
                    }
                    //MARK: Disattivo le bounding box che non servono
                    for i in stride(from: self!.knownObstacles.count, to: Constants.MAX_OBSTACLE_NUMBER, by: 1)
                    {
                        self!.boundingBoxes[i].hide()
                    }
                }
                
                let end = DispatchTime.now()
                let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds // <<<<< Difference in nano seconds (UInt64)
                    let timeInterval = Double(nanoTime) / 1_000_000_000 // Technically could overflow for long running tests
                //print(timeInterval)
                self!.classification=false
            }
        }
    }
}
